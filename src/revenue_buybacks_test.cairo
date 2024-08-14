use core::num::traits::{Zero};
use core::option::{OptionTrait};
use core::serde::{Serde};
use core::traits::{TryInto};
use ekubo::components::owned::{IOwnedDispatcher, IOwnedDispatcherTrait};
use ekubo::extensions::interfaces::twamm::{OrderKey};
use ekubo::interfaces::core::{
    ICoreDispatcherTrait, ICoreDispatcher, IExtensionDispatcher, IExtensionDispatcherTrait
};
use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use ekubo::interfaces::erc721::{IERC721Dispatcher, IERC721DispatcherTrait};
use ekubo::interfaces::mathlib::{IMathLibDispatcher};
use ekubo::interfaces::positions::{IPositionsDispatcher, IPositionsDispatcherTrait};
use ekubo::interfaces::router::{IRouterDispatcher, IRouterDispatcherTrait, RouteNode, TokenAmount};
use ekubo::types::i129::{i129};
use ekubo::types::keys::{PoolKey, PositionKey};
use ekubo_rb::revenue_buybacks::{
    IRevenueBuybacksDispatcher, IRevenueBuybacksDispatcherTrait, Config
};
use snforge_std::{
    declare, ContractClassTrait, cheat_caller_address, stop_cheat_caller_address,
    start_cheat_block_timestamp_global, CheatSpan, ContractClass, DeclareResultTrait
};
use starknet::{
    get_contract_address, get_block_timestamp, contract_address_const,
    storage_access::{StorePacking}, syscalls::{deploy_syscall}, ContractAddress
};

fn deploy_revenue_buybacks(config: Config) -> IRevenueBuybacksDispatcher {
    let contract = declare("RevenueBuybacks").unwrap().contract_class();

    let mut args: Array<felt252> = array![];
    Serde::serialize(@(governor_address(), ekubo_core(), positions(), config), ref args,);
    let (contract_address, _) = contract.deploy(@args).expect('Deploy failed');

    IRevenueBuybacksDispatcher { contract_address }
}

fn ekubo_core() -> ICoreDispatcher {
    ICoreDispatcher {
        contract_address: contract_address_const::<
            0x00000005dd3D2F4429AF886cD1a3b08289DBcEa99A294197E9eB43b0e0325b4b
        >()
    }
}

fn ekubo_token() -> IERC20Dispatcher {
    IERC20Dispatcher {
        contract_address: contract_address_const::<
            0x075afe6402ad5a5c20dd25e10ec3b3986acaa647b77e4ae24b0cbc9a54a27a87
        >()
    }
}

fn positions() -> IPositionsDispatcher {
    IPositionsDispatcher {
        contract_address: contract_address_const::<
            0x02e0af29598b407c8716b17f6d2795eca1b471413fa03fb145a5e33722184067
        >()
    }
}

fn router() -> IRouterDispatcher {
    IRouterDispatcher {
        contract_address: contract_address_const::<
            0x0199741822c2dc722f6f605204f35e56dbc23bceed54818168c4c49e4fb8737e
        >()
    }
}

fn governor_address() -> ContractAddress {
    contract_address_const::<0x053499f7aa2706395060fe72d00388803fb2dcc111429891ad7b2d9dcea29acd>()
}

fn eth_token() -> ContractAddress {
    contract_address_const::<0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7>()
}


// Deploys the revenue buybacks with the specified config or a default config and makes it the owner
// of ekubo core
fn setup(config: Option<Config>) -> IRevenueBuybacksDispatcher {
    let rb = deploy_revenue_buybacks(
        config
            .unwrap_or(
                Config {
                    buy_token: ekubo_token().contract_address,
                    min_delay: 0,
                    max_delay: 43200,
                    // 30 seconds
                    min_duration: 30,
                    // 7 days
                    max_duration: 604800,
                    // 30 bips
                    fee: 1020847100762815411640772995208708096
                }
            )
    );
    let core = ekubo_core();
    cheat_caller_address(core.contract_address, governor_address(), CheatSpan::Indefinite);
    IOwnedDispatcher { contract_address: core.contract_address }
        .transfer_ownership(rb.contract_address);
    stop_cheat_caller_address(core.contract_address);
    rb
}

fn advance_time(by: u64) -> u64 {
    let time = get_block_timestamp();
    let next = time + by;
    start_cheat_block_timestamp_global(next);
    next
}

#[test]
#[fork("mainnet")]
fn test_setup_sets_owner() {
    let rb = setup(config: Option::None);
    assert_eq!(
        IOwnedDispatcher { contract_address: rb.contract_address }.get_owner(), governor_address()
    );
    assert_eq!(
        IOwnedDispatcher { contract_address: ekubo_core().contract_address }.get_owner(),
        rb.contract_address
    );
}

#[test]
#[fork("mainnet")]
fn test_eth_buybacks() {
    let rb = setup(config: Option::None);
    let start_time = (get_block_timestamp() / 16) * 16;
    let end_time = start_time + (16 * 8);

    let protocol_revenue_eth = ekubo_core().get_protocol_fees_collected(eth_token());
    rb.start_buybacks_all(sell_token: eth_token(), start_time: start_time, end_time: end_time);

    let config = rb.get_config(eth_token());

    let order_key = OrderKey {
        sell_token: eth_token(),
        buy_token: ekubo_token().contract_address,
        fee: config.fee,
        start_time,
        end_time
    };

    let order_info = positions().get_order_info(id: rb.get_token_id(), order_key: order_key);

    // rounding error may not be sold
    assert_lt!(protocol_revenue_eth - order_info.remaining_sell_amount, 2);
    assert_eq!(order_info.purchased_amount, 0);

    advance_time(end_time - get_block_timestamp());

    let order_info_after = positions().get_order_info(id: rb.get_token_id(), order_key: order_key);

    assert_eq!(order_info_after.remaining_sell_amount, 0);
    assert_gt!(order_info_after.purchased_amount, 0);

    let balance_before = ekubo_token().balanceOf(governor_address());
    rb.collect_proceeds_to_owner(order_key);
    let balance_after = ekubo_token().balanceOf(governor_address());
    assert_eq!(balance_after - balance_before, order_info_after.purchased_amount.into());
}


#[test]
#[fork("mainnet")]
fn test_reclaim_core() {
    let rb = setup(config: Option::None);

    cheat_caller_address(rb.contract_address, governor_address(), CheatSpan::Indefinite);
    rb.reclaim_core();
    stop_cheat_caller_address(rb.contract_address);
    assert_eq!(
        IOwnedDispatcher { contract_address: ekubo_core().contract_address }.get_owner(),
        governor_address()
    );
    assert_eq!(
        IERC721Dispatcher { contract_address: positions().get_nft_address() }
            .ownerOf(rb.get_token_id().into()),
        rb.contract_address
    );
}

