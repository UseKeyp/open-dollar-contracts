// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import '@script/Registry.s.sol';
import {IERC20} from '@openzeppelin/token/ERC20/IERC20.sol';
import {OD_INITIAL_PRICE} from '@script/Params.s.sol';
import {Deploy} from '@script/Deploy.s.sol';
import {
  Contracts, ICollateralJoin, MintableERC20, IERC20Metadata, IBaseOracle, ISAFEEngine
} from '@script/Contracts.s.sol';
import {ODProxy} from '@contracts/proxies/ODProxy.sol';
import {IDelayedOracle} from '@interfaces/oracles/IDelayedOracle.sol';
import {Math, RAY} from '@libraries/Math.sol';
import {ODTest} from '@test/utils/ODTest.t.sol';
import {TestParams, WSTETH, RETH, ARB, WETH, TKN, TEST_ETH_PRICE, TEST_TKN_PRICE} from '@test/e2e/TestParams.t.sol';
import {ERC20ForTest} from '@test/mocks/ERC20ForTest.sol';
import {OracleForTest} from '@test/mocks/OracleForTest.sol';
import {DelayedOracleForTest} from '@test/mocks/DelayedOracleForTest.sol';

uint256 constant RAD_DELTA = 0.0001e45;
uint256 constant COLLATERAL_PRICE = 100e18;

uint256 constant COLLAT = 1e18;
uint256 constant DEBT = 500e18; // LVT 50%
uint256 constant TEST_ETH_PRICE_DROP = 100e18; // 1 ETH = 100 OD

/**
 * @title  DeployForTest
 * @notice Contains the deployment initialization routine for test environments
 */
contract DeployForTest is TestParams, Deploy {
  constructor() {
    // NOTE: creates fork in order to have WSTETH at 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1
    vm.createSelectFork(vm.rpcUrl('mainnet'));
    _isTest = true;
  }

  function setupEnvironment() public virtual override {
    systemCoinOracle = new OracleForTest(OD_INITIAL_PRICE); // 1 OD = 1 USD

    collateral[WETH] = IERC20Metadata(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    collateral[RETH] = IERC20Metadata(0xEC70Dcb4A1EFa46b8F2D97C310C9c4790ba5ffA8);
    collateral[WSTETH] = IERC20Metadata(0x5979D7b546E38E414F7E9822514be443A4800529);
    collateral[ARB] = IERC20Metadata(0x912CE59144191C1204E64559FE8253a0e49E6548);
    collateral[TKN] = new ERC20ForTest();

    delayedOracle[WETH] = new DelayedOracleForTest(TEST_ETH_PRICE, address(0));
    delayedOracle[RETH] = new DelayedOracleForTest(TEST_ETH_PRICE, address(0));
    delayedOracle[WSTETH] = new DelayedOracleForTest(TEST_ETH_PRICE, address(0));
    delayedOracle[ARB] = new DelayedOracleForTest(TEST_ETH_PRICE, address(0));
    delayedOracle[TKN] = new DelayedOracleForTest(TEST_TKN_PRICE, address(0));
    delayedOracle['TKN-A'] = new DelayedOracleForTest(COLLATERAL_PRICE, address(0));
    delayedOracle['TKN-B'] = new DelayedOracleForTest(COLLATERAL_PRICE, address(0));
    delayedOracle['TKN-C'] = new DelayedOracleForTest(COLLATERAL_PRICE, address(0));
    delayedOracle['TKN-8D'] = new DelayedOracleForTest(COLLATERAL_PRICE, address(0));

    collateral['TKN-A'] = new ERC20ForTest();
    collateral['TKN-B'] = new ERC20ForTest();
    collateral['TKN-C'] = new ERC20ForTest();
    collateral['TKN-8D'] = new MintableERC20('8 Decimals TKN', 'TKN', 8);

    collateralTypes.push(WETH);
    collateralTypes.push(RETH);
    collateralTypes.push(WSTETH);
    collateralTypes.push(ARB);
    collateralTypes.push(TKN);
    collateralTypes.push('TKN-A');
    collateralTypes.push('TKN-B');
    collateralTypes.push('TKN-C');
    collateralTypes.push('TKN-8D');

    _getEnvironmentParams();
  }
}

/**
 * @title  Common
 * @notice Abstract contract that contains for test methods, and triggers DeployForTest routine
 * @dev    Used to be inherited by different test contracts with different scopes
 */
abstract contract Common is DeployForTest, ODTest {
  address public alice = address(0x420);
  address public bob = address(0x421);
  address public carol = address(0x422);
  address public dave = address(0x423);

  uint256 public auctionId;

  mapping(address proxy => uint256 safeId) public vaults;

  function setUp() public virtual {
    run();

    for (uint256 i = 0; i < collateralTypes.length; i++) {
      bytes32 _cType = collateralTypes[i];
      taxCollector.taxSingle(_cType);
    }

    vm.label(deployer, 'Deployer');
    vm.label(alice, 'Alice');
    vm.label(bob, 'Bob');
    vm.label(carol, 'Carol');
    vm.label(dave, 'Dave');

    vm.startPrank(deployer); // no governor on test deployment
    accountingEngine.modifyParameters('extraSurplusReceiver', abi.encode(address(0x420)));

    vm.stopPrank();
  }

  function _setCollateralPrice(bytes32 _collateral, uint256 _price) internal {
    IBaseOracle _oracle = oracleRelayer.cParams(_collateral).oracle;
    vm.mockCall(
      address(_oracle), abi.encodeWithSelector(IBaseOracle.getResultWithValidity.selector), abi.encode(_price, true)
    );
    vm.mockCall(address(_oracle), abi.encodeWithSelector(IBaseOracle.read.selector), abi.encode(_price));
    oracleRelayer.updateCollateralPrice(_collateral);
  }

  function _collectFees(bytes32 _cType, uint256 _timeToWarp) internal {
    vm.warp(block.timestamp + _timeToWarp);
    taxCollector.taxSingle(_cType);
  }

  /// @dev Extra Test Setup Helper Functions

  function deployOrFind(address _owner) public virtual returns (address) {
    address proxy = vault721.getProxy(_owner);
    if (proxy == address(0)) {
      return address(vault721.build(_owner));
    } else {
      return proxy;
    }
  }

  function openSafe(address _proxy, bytes32 _cType) public virtual {
    vm.prank(_proxy);
    vaults[_proxy] = safeManager.openSAFE(_cType, _proxy);
  }

  function userVaultSetup(
    bytes32 _cType,
    address _user,
    uint256 _amount,
    string memory _name
  ) public virtual returns (address _proxy) {
    _proxy = deployOrFind(_user);
    mintToken(_cType, _user, _amount, _proxy);
    vm.label(_proxy, _name);
    vm.prank(_proxy);
    vaults[_proxy] = safeManager.openSAFE(_cType, _proxy);
  }

  function getSAFE(bytes32 _cType, address _safe) public view virtual returns (uint256 _collateral, uint256 _debt) {
    ISAFEEngine.SAFE memory _safeData = safeEngine.safes(_cType, _safe);
    _collateral = _safeData.lockedCollateral;
    _debt = _safeData.generatedDebt;
  }

  function depositCollateralAndGenDebt(
    bytes32 _cType,
    uint256 _safeId,
    uint256 _collatAmount,
    uint256 _deltaWad,
    address _proxy
  ) public virtual {
    vm.startPrank(ODProxy(_proxy).OWNER());
    bytes memory _payload = abi.encodeWithSelector(
      basicActions.lockTokenCollateralAndGenerateDebt.selector,
      address(safeManager),
      address(collateralJoin[_cType]),
      address(coinJoin),
      _safeId,
      _collatAmount,
      _deltaWad
    );
    ODProxy(_proxy).execute(address(basicActions), _payload);
    vm.stopPrank();
  }

  function buyCollateral(
    bytes32 _cType,
    uint256 _auctionId,
    uint256 _minCollateral,
    uint256 _bid,
    address _proxy
  ) public virtual {
    vm.startPrank(ODProxy(_proxy).OWNER());
    bytes memory _payload = abi.encodeWithSelector(
      collateralBidActions.buyCollateral.selector,
      address(coinJoin),
      address(collateralJoin[_cType]),
      address(collateralAuctionHouse[_cType]),
      _auctionId,
      _minCollateral,
      _bid
    );
    ODProxy(_proxy).execute(address(collateralBidActions), _payload);
    vm.stopPrank();
  }

  function mintToken(bytes32 _cType, address _account, uint256 _amount, address _okAccount) public virtual {
    vm.startPrank(_account);
    deal(address(collateral[_cType]), _account, _amount);
    if (_okAccount != address(0)) {
      IERC20(address(collateral[_cType])).approve(_okAccount, _amount);
    }
    vm.stopPrank();
  }
}
