// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {LiquidityBase} from '@script/dexpool/base/LiquidityBase.s.sol';

// BROADCAST
// source .env && forge script GetCamelotPair --with-gas-price 2000000000 -vvvvv --rpc-url $ARB_GOERLI_RPC --broadcast --verify --etherscan-api-key $ARB_ETHERSCAN_API_KEY

// SIMULATE
// source .env && forge script GetCamelotPair --with-gas-price 2000000000 -vvvvv --rpc-url $ARB_GOERLI_RPC

contract GetCamelotPair is LiquidityBase {
  address public pair;

  function run() public {
    vm.startBroadcast(vm.envUint('ARB_GOERLI_PK'));
    pair = camelotV2Factory.getPair(tokenA, tokenB);
    vm.stopBroadcast();
  }
}
