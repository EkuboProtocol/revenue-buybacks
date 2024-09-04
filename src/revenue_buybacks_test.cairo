use core::serde::{Serde};
use ekubo::components::owned::{IOwnedDispatcher, IOwnedDispatcherTrait};
use ekubo::extensions::interfaces::twamm::{OrderKey};
use ekubo::interfaces::core::{ICoreDispatcherTrait, ICoreDispatcher};
use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use ekubo::interfaces::erc721::{IERC721Dispatcher, IERC721DispatcherTrait};
use ekubo::interfaces::positions::{IPositionsDispatcher, IPositionsDispatcherTrait};
use ekubo::interfaces::router::{IRouterDispatcher};
use ekubo_rb::revenue_buybacks::{
    IRevenueBuybacksDispatcher, IRevenueBuybacksDispatcherTrait, Config
};
use snforge_std::{
    declare, DeclareResultTrait, ContractClassTrait, cheat_caller_address,
    stop_cheat_caller_address, start_cheat_block_timestamp_global, CheatSpan,
};
use starknet::{get_block_timestamp, contract_address_const, ContractAddress};

fn deploy_revenue_buybacks(default_config: Option<Config>) -> IRevenueBuybacksDispatcher {
    let contract = declare("RevenueBuybacks").unwrap().contract_class();

    let mut args: Array<felt252> = array![];
    Serde::serialize(@(governor_address(), ekubo_core(), positions(), default_config), ref args);
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


fn example_config() -> Config {
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
}

// Deploys the revenue buybacks with the specified config or a default config and makes it the owner
// of ekubo core
fn setup(default_config: Option<Config>) -> IRevenueBuybacksDispatcher {
    let rb = deploy_revenue_buybacks(default_config);
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
fn test_setup() {
    let rb = setup(default_config: Option::Some(example_config()));
    assert_eq!(
        IOwnedDispatcher { contract_address: rb.contract_address }.get_owner(), governor_address()
    );
    assert_eq!(
        IOwnedDispatcher { contract_address: ekubo_core().contract_address }.get_owner(),
        rb.contract_address
    );
    assert_eq!(rb.get_core(), ekubo_core().contract_address);
    assert_eq!(rb.get_positions(), positions().contract_address);
    // the owner of the minted positions token is the revenue buybacks contract
    assert_eq!(
        IERC721Dispatcher {
            contract_address: IPositionsDispatcher { contract_address: rb.get_positions() }
                .get_nft_address()
        }
            .owner_of(rb.get_token_id().into()),
        rb.contract_address
    );
    // default config, so any address will do
    assert_eq!(rb.get_config(sell_token: contract_address_const::<0xdeadbeef>()), example_config());
}

#[test]
#[fork("mainnet")]
fn test_eth_buybacks() {
    let rb = setup(default_config: Option::Some(example_config()));
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
#[should_panic(expected: ('Invalid sell token',))]
fn test_same_token_buyback_fails() {
    let rb = setup(default_config: Option::Some(example_config()));
    let start_time = (get_block_timestamp() / 16) * 16;
    let end_time = start_time + (16 * 8);

    rb
        .start_buybacks_all(
            sell_token: ekubo_token().contract_address, start_time: start_time, end_time: end_time
        );
}


#[test]
#[fork("mainnet")]
#[should_panic(expected: ('No config for token',))]
fn test_buyback_with_no_config() {
    let rb = setup(default_config: Option::None);
    rb.get_config(sell_token: eth_token());
}


#[test]
#[fork("mainnet")]
fn test_buyback_with_config_override() {
    let rb = setup(default_config: Option::None);
    cheat_caller_address(rb.contract_address, governor_address(), CheatSpan::Indefinite);
    rb
        .set_config_override(
            sell_token: eth_token(), config_override: Option::Some(example_config())
        );
    stop_cheat_caller_address(rb.contract_address);

    assert_eq!(rb.get_config(sell_token: eth_token()), example_config());

    let start_time = (get_block_timestamp() / 16) * 16;
    let end_time = start_time + (16 * 8);

    rb.start_buybacks_all(sell_token: eth_token(), start_time: start_time, end_time: end_time);
}


#[test]
#[fork("mainnet")]
fn test_reclaim_core() {
    let rb = setup(default_config: Option::Some(example_config()));

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

