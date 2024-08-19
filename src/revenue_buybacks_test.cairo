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
            0x0444a09d96389aa7148f1aada508e30b71299ffe650d9c97fdaae38cb9a23384
        >()
    }
}

fn ekubo_token() -> IERC20Dispatcher {
    IERC20Dispatcher {
        contract_address: contract_address_const::<
            0x01fad7c03b2ea7fbef306764e20977f8d4eae6191b3a54e4514cc5fc9d19e569
        >()
    }
}

fn positions() -> IPositionsDispatcher {
    IPositionsDispatcher {
        contract_address: contract_address_const::<
            0x06a2aee84bb0ed5dded4384ddd0e40e9c1372b818668375ab8e3ec08807417e5
        >()
    }
}

fn router() -> IRouterDispatcher {
    IRouterDispatcher {
        contract_address: contract_address_const::<
            0x0045f933adf0607292468ad1c1dedaa74d5ad166392590e72676a34d01d7b763
        >()
    }
}

fn governor_address() -> ContractAddress {
    contract_address_const::<0x048bb83134ce6a312d1b41b0b3deccc4ce9a9d280e6c68c0eb1c517259c89d74>()
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
#[fork("sepolia")]
fn test_setup_sets_owner() {
    let rb = setup(default_config: Option::Some(example_config()));
    assert_eq!(
        IOwnedDispatcher { contract_address: rb.contract_address }.get_owner(), governor_address()
    );
    assert_eq!(
        IOwnedDispatcher { contract_address: ekubo_core().contract_address }.get_owner(),
        rb.contract_address
    );
}

#[test]
#[fork("sepolia")]
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
#[fork("sepolia")]
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

