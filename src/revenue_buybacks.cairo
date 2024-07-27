use core::traits::{Into, TryInto};
use ekubo::extensions::interfaces::twamm::{OrderKey};
use ekubo::types::i129::{i129, i129Trait};
use starknet::{ContractAddress, ClassHash, storage_access::{StorePacking}};

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct Config {
    // The token that will be purchased in the buybacks
    pub buy_token: ContractAddress,
    // The minimum amount of time that can be between the start time and the current time. A value of 0 means the orders _can_ start immediately
    pub min_delay: u64,
    // The maximum amount of time that can be between the start time and the current time. A value of 0 means that the orders _must_ start immediately
    pub max_delay: u64,
    // The minimum duration of the buyback
    pub min_duration: u64,
    // The maximum duration of the buyback
    pub max_duration: u64,
    // The fee of the pool on which to place the TWAMM orders
    pub fee: u128,
}

#[starknet::interface]
pub trait IRevenueBuybacks<TContractState> {
    // Returns the core contract from which the revenue is withdrawn
    fn get_core(self: @TContractState) -> ContractAddress;

    // Returns the positions contract that is used by this contract to implement the buybacks
    fn get_positions(self: @TContractState) -> ContractAddress;

    // Returns the NFT token ID for the positions contract with which all the sell orders are associated
    fn get_token_id(self: @TContractState) -> u64;

    // Returns the configuration of this contract
    fn get_config(self: @TContractState, sell_token: ContractAddress) -> Config;

    // Withdraws revenue from the core contract and begins a sale
    fn start_buybacks(
        ref self: TContractState,
        sell_token: ContractAddress,
        amount: u128,
        start_time: u64,
        end_time: u64
    );

    // Withdraws _all_ revenue and starts buybacks
    fn start_buybacks_all(
        ref self: TContractState, sell_token: ContractAddress, start_time: u64, end_time: u64
    );

    // Collects the proceeds for a particular order
    fn collect_proceeds_to_owner(ref self: TContractState, order_key: OrderKey);

    // Sets the default config
    fn set_default_config(ref self: TContractState, config: Config);

    // Overrides the config for the given token. Only callable by the owner.
    fn set_config_for_token(ref self: TContractState, sell_token: ContractAddress, config: Config);

    // Takes ownership of core back from this contract. Only callable by the owner.
    fn reclaim_core(ref self: TContractState);
}

#[starknet::contract]
pub mod RevenueBuybacks {
    use core::array::{ArrayTrait};
    use core::cmp::{max};
    use core::num::traits::{Zero};
    use core::option::{OptionTrait};
    use core::traits::{TryInto, Into};
    use ekubo::components::clear::{IClearDispatcher, IClearDispatcherTrait};
    use ekubo::components::owned::{
        IOwned, IOwnedDispatcher, IOwnedDispatcherTrait, Ownable, Owned as owned_component
    };
    use ekubo::components::shared_locker::{call_core_with_callback, consume_callback_data};
    use ekubo::interfaces::core::{
        IExtension, SwapParameters, UpdatePositionParameters, ILocker, ICoreDispatcher,
        ICoreDispatcherTrait
    };
    use ekubo::interfaces::erc20::{IERC20Dispatcher};
    use ekubo::interfaces::erc721::{IERC721Dispatcher, IERC721DispatcherTrait};
    use ekubo::interfaces::positions::{IPositionsDispatcher, IPositionsDispatcherTrait};

    use ekubo::types::keys::{PoolKey, PositionKey};
    use ekubo::types::keys::{SavedBalanceKey};
    use starknet::{get_block_timestamp, get_contract_address, get_caller_address, ClassHash};
    use super::{IRevenueBuybacks, i129, i129Trait, ContractAddress, Config, OrderKey};

    component!(path: owned_component, storage: owned, event: OwnedEvent);
    #[abi(embed_v0)]
    impl Owned = owned_component::OwnedImpl<ContractState>;
    impl OwnableImpl = owned_component::OwnableImpl<ContractState>;

    #[storage]
    struct Storage {
        core: ICoreDispatcher,
        positions: IPositionsDispatcher,
        config: Config,
        config_overrides: LegacyMap<ContractAddress, Option<Config>>,
        // the NFT token ID that all orders are associated with. we use just one so ownership can be simply transferred
        token_id: u64,
        #[substorage(v0)]
        owned: owned_component::Storage,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        core: ICoreDispatcher,
        positions: IPositionsDispatcher,
        config: Config,
    ) {
        self.initialize_owned(owner);
        self.core.write(core);
        self.positions.write(positions);
        self.config.write(config);
        self.token_id.write(positions.mint_v2(Zero::zero()));
    }

    #[derive(starknet::Event, Drop)]
    #[event]
    enum Event {
        OwnedEvent: owned_component::Event,
    }

    #[abi(embed_v0)]
    impl RevenueBuybacksImpl of IRevenueBuybacks<ContractState> {
        fn get_core(self: @ContractState) -> ContractAddress {
            self.core.read().contract_address
        }

        fn get_positions(self: @ContractState) -> ContractAddress {
            self.positions.read().contract_address
        }

        fn get_token_id(self: @ContractState) -> u64 {
            self.token_id.read()
        }

        fn get_config(self: @ContractState, sell_token: ContractAddress) -> Config {
            self.config_overrides.read(sell_token).unwrap_or(self.config.read())
        }

        fn start_buybacks(
            ref self: ContractState,
            sell_token: ContractAddress,
            amount: u128,
            start_time: u64,
            end_time: u64
        ) {
            let config = self.get_config(sell_token);

            let current_time = get_block_timestamp();
            assert(config.buy_token != sell_token, 'Invalid sell token');
            assert(end_time > start_time, 'Invalid start or end time');
            let actual_start = max(current_time, start_time);
            assert(end_time > actual_start, 'End time expired');
            let duration = end_time - actual_start;
            assert(duration >= config.min_duration, 'Duration too short');
            assert(duration <= config.max_duration, 'Duration too long');
            // Enforce the order starts within the min/max delay
            if (config.min_delay.is_non_zero()) {
                assert(
                    start_time > current_time && (start_time - current_time) >= config.min_delay,
                    'Order must start > min delay'
                );
            }
            // if it starts in the future, make sure it's not too far in the future
            if (start_time > current_time) {
                assert(
                    (start_time - current_time) < config.max_delay, 'Order must start < max delay'
                );
            }

            let positions = self.positions.read();
            let token_id = self.token_id.read();
            self.core.read().withdraw_protocol_fees(positions.contract_address, sell_token, amount);
            positions
                .increase_sell_amount(
                    token_id,
                    OrderKey {
                        sell_token,
                        buy_token: config.buy_token,
                        fee: config.fee,
                        start_time,
                        end_time
                    },
                    amount
                );
        }

        fn start_buybacks_all(
            ref self: ContractState, sell_token: ContractAddress, start_time: u64, end_time: u64
        ) {
            self
                .start_buybacks(
                    sell_token,
                    self.core.read().get_protocol_fees_collected(sell_token),
                    start_time,
                    end_time
                );
        }

        fn collect_proceeds_to_owner(ref self: ContractState, order_key: OrderKey) {
            let positions = self.positions.read();
            let twamm = IClearDispatcher { contract_address: positions.get_twamm_address() };
            positions.withdraw_proceeds_from_sale(self.token_id.read(), order_key);
            twamm
                .clear_minimum_to_recipient(
                    IERC20Dispatcher { contract_address: order_key.buy_token },
                    minimum: 0,
                    recipient: self.get_owner()
                );
        }

        fn set_default_config(ref self: ContractState, config: Config) {
            self.require_owner();
            self.config.write(config);
        }

        fn set_config_for_token(
            ref self: ContractState, sell_token: ContractAddress, config: Config
        ) {
            self.require_owner();
            self.config_overrides.write(sell_token, Option::Some(config));
        }

        fn reclaim_core(ref self: ContractState) {
            self.require_owner();
            let owner = self.get_owner();
            IOwnedDispatcher { contract_address: self.core.read().contract_address }
                .transfer_ownership(owner);
        }
    }
}
