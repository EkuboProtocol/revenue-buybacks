use core::num::traits::{Zero};
use core::option::{OptionTrait};
use core::serde::{Serde};
use core::traits::{TryInto};
use ekubo::components::owned::{IOwnedDispatcher, IOwnedDispatcherTrait};
use ekubo::interfaces::core::{
    ICoreDispatcherTrait, ICoreDispatcher, IExtensionDispatcher, IExtensionDispatcherTrait
};
use ekubo::interfaces::erc20::{IERC20Dispatcher};
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
    cheat_block_timestamp, CheatSpan, ContractClass
};
use starknet::{
    get_contract_address, get_block_timestamp, contract_address_const,
    storage_access::{StorePacking}, syscalls::{deploy_syscall}, ContractAddress
};

fn deploy_token(
    class: ContractClass, recipient: ContractAddress, amount: u256
) -> IERC20Dispatcher {
    let (contract_address, _) = class
        .deploy(@array![recipient.into(), amount.low.into(), amount.high.into()])
        .expect('Deploy token failed');

    IERC20Dispatcher { contract_address }
}

fn deploy_revenue_buybacks() -> IRevenueBuybacksDispatcher {
    let contract = declare("RevenueBuybacks").unwrap();
    let mut args: Array<felt252> = array![];
    Serde::serialize(
        @(
            get_contract_address(),
            ekubo_core(),
            positions(),
            Config {
                buy_token: ekubo_token().contract_address,
                // 30 seconds
                min_duration: 30,
                // 7 days
                max_duration: 604800,
                // 30 bips
                fee: 1020847100762815411640772995208708096
            }
        ),
        ref args,
    );
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

#[test]
#[fork("mainnet")]
fn test_eth_buybacks() {
    let rb = deploy_revenue_buybacks();
    let core = ekubo_core();
    cheat_caller_address(core.contract_address, governor_address(), CheatSpan::Indefinite);
    IOwnedDispatcher { contract_address: core.contract_address }
        .transfer_ownership(rb.contract_address);
    stop_cheat_caller_address(core.contract_address);

    rb
        .start_buybacks_all(
            contract_address_const::<
                0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7
            >(),
            (get_block_timestamp() / 16) * 16,
            ((get_block_timestamp() / 16) + 8) * 16
        );
}

