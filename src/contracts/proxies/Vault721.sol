// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {ERC721Upgradeable, IERC721Upgradeable} from '@openzeppelin-upgradeable/token/ERC721/ERC721Upgradeable.sol';
import {ERC721EnumerableUpgradeable} from
  '@openzeppelin-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol';
import {IODSafeManager} from '@interfaces/proxies/IODSafeManager.sol';
import {ODProxy} from '@contracts/proxies/ODProxy.sol';
import {NFTRenderer} from '@contracts/proxies/NFTRenderer.sol';
import {ISAFEEngine} from '@interfaces/ISAFEEngine.sol';

// Open Dollar
// Version 1.6.1

struct HashState {
  bytes32 lastHash;
  uint256 lastBlockNumber;
  uint256 lastBlockTimestamp;
}

/**
 * @notice Upgradeable contract used as singleton, but is not upgradeable
 */
contract Vault721 is ERC721EnumerableUpgradeable {
  error NotGovernor();
  error NotSafeManager();
  error NotWallet();
  error ProxyAlreadyExist();
  error BlockDelayNotOver();
  error TimeDelayNotOver();
  error ZeroAddress();
  error StateViolation();

  address public timelockController;
  IODSafeManager public safeManager;
  NFTRenderer public nftRenderer;
  uint256 public blockDelay;
  uint256 public timeDelay;

  struct NFVState {
    uint256 collateral;
    uint256 debt;
    uint256 lastBlockNumber;
    uint256 lastBlockTimestamp;
  }

  string public contractMetaData =
    '{"name": "Open Dollar Vaults","description": "Open Dollar is a DeFi lending protocol that enables borrowing against liquid staking tokens while earning staking rewards and enabling liquidity via Non-Fungible Vaults (NFVs).","image": "https://app.opendollar.com/collectionImage.png","external_link": "https://app.opendollar.com"}';

  mapping(address proxy => address user) internal _proxyRegistry;
  mapping(address user => address proxy) internal _userRegistry;
  mapping(uint256 vaultId => NFVState nfvState) internal _nfvState;
  mapping(address nftExchange => bool whitelisted) internal _allowlist;

  event CreateProxy(address indexed _user, address indexed _proxy);

  /**
   * @dev initializes DAO timelockController contract
   */
  function initialize(address _timelockController) external initializer nonZero(_timelockController) {
    timelockController = _timelockController;
    __ERC721_init('OpenDollar Vault', 'ODV');
  }

  /**
   * @dev control access for DAO timelockController
   */
  modifier onlyGovernance() {
    if (msg.sender != timelockController) revert NotGovernor();
    _;
  }

  /**
   * @dev control access for SafeManager
   */
  modifier onlySafeManager() {
    if (msg.sender != address(safeManager)) revert NotSafeManager();
    _;
  }

  /**
   * @dev enforce non-zero address params
   */
  modifier nonZero(address _addr) {
    if (_addr == address(0)) revert ZeroAddress();
    _;
  }

  /**
   * @dev initializes SafeManager contract
   */
  function initializeManager() external {
    if (address(safeManager) == address(0)) _setSafeManager(msg.sender);
  }

  /**
   * @dev initializes NFTRenderer contract
   */
  function initializeRenderer() external {
    if (address(nftRenderer) == address(0)) _setNftRenderer(msg.sender);
  }

  /**
   * @dev get proxy by user address
   */
  function getProxy(address _user) external view returns (address _proxy) {
    _proxy = _userRegistry[_user];
  }

  /**
   * @dev get nfv state by vault id
   */
  function getNfvState(uint256 _vaultId) external view returns (NFVState memory) {
    return _nfvState[_vaultId];
  }

  function getIsAllowlisted(address _user) external view returns (bool) {
    return _allowlist[_user];
  }

  /**
   * @dev allows msg.sender without an ODProxy to deploy a new ODProxy
   */
  function build() external returns (address payable _proxy) {
    if (!_shouldBuildProxy(msg.sender)) revert ProxyAlreadyExist();
    _proxy = _build(msg.sender);
  }

  /**
   * @dev allows user without an ODProxy to deploy a new ODProxy
   */
  function build(address _user) external returns (address payable _proxy) {
    if (!_shouldBuildProxy(_user)) revert ProxyAlreadyExist();
    _proxy = _build(_user);
  }

  /**
   * @dev allows user to deploy proxies for multiple users
   * @param _users array of user addresses
   * @return _proxies array of proxy addresses
   */
  function build(address[] memory _users) external returns (address payable[] memory _proxies) {
    uint256 len = _users.length;
    _proxies = new address payable[](len);
    for (uint256 i = 0; i < len; i++) {
      if (!_shouldBuildProxy(_users[i])) revert ProxyAlreadyExist();
      _proxies[i] = _build(_users[i]);
    }
  }

  /**
   * @dev mint can only be called by the SafeManager
   * enforces that only ODProxies call `openSafe` function by checking _proxyRegistry
   */
  function mint(address _proxy, uint256 _safeId) external onlySafeManager {
    require(_proxyRegistry[_proxy] != address(0), 'V721: non-native proxy');
    address _user = _proxyRegistry[_proxy];
    _safeMint(_user, _safeId);
  }

  /**
   * @dev allows DAO to update protocol implementation on NFTRenderer
   */
  function updateNftRenderer(
    address _nftRenderer,
    address _oracleRelayer,
    address _taxCollector,
    address _collateralJoinFactory
  ) external onlyGovernance nonZero(_oracleRelayer) nonZero(_taxCollector) nonZero(_collateralJoinFactory) {
    address _safeManager = address(safeManager);
    require(_safeManager != address(0));
    _setNftRenderer(_nftRenderer);
    nftRenderer.setImplementation(_safeManager, _oracleRelayer, _taxCollector, _collateralJoinFactory);
  }

  /**
   * @dev allows ODSafeManager to update the nfv state in nfvState mapping
   */
  function updateNfvState(uint256 _vaultId) external onlySafeManager {
    (uint256 _collateral, uint256 _debt) = _getNfvValue(_vaultId);

    _nfvState[_vaultId] = NFVState({
      collateral: _collateral,
      debt: _debt,
      lastBlockNumber: block.number,
      lastBlockTimestamp: block.timestamp
    });
  }

  /**
   * @dev allows DAO to update allowlist
   */
  function updateAllowlist(address _user, bool _allowed) external onlyGovernance nonZero(_user) {
    _allowlist[_user] = _allowed;
  }

  /**
   * @dev allows DAO to update the time delay
   */
  function updateTimeDelay(uint256 _timeDelay) external onlyGovernance {
    timeDelay = _timeDelay;
  }

  /**
   * @dev allows DAO to update the block delay
   */
  function updateBlockDelay(uint256 _blockDelay) external onlyGovernance {
    blockDelay = _blockDelay;
  }

  /**
   * @dev update meta data
   */
  function updateContractURI(string memory _metaData) external onlyGovernance {
    contractMetaData = _metaData;
  }

  /**
   * @dev allows DAO to update protocol implementation of SafeManager
   *
   * WARNING: This function should not be called unless the new SafeManager
   * is capable of correctly persisting the proper safeId as it relates to the
   * current tokenId. Additional considerations regarding data migration of
   * core contracts should be addressed.
   */
  function setSafeManager(address _safeManager) external onlyGovernance {
    _setSafeManager(_safeManager);
  }

  /**
   * @dev allows DAO to update protocol implementation of NFTRenderer
   */
  function setNftRenderer(address _nftRenderer) external onlyGovernance {
    _setNftRenderer(_nftRenderer);
  }

  /**
   * @dev generate URI with updated vault information
   */
  function tokenURI(uint256 _safeId) public view override returns (string memory uri) {
    _requireMinted(_safeId);
    uri = nftRenderer.render(_safeId);
  }

  /**
   * @dev contract level meta data
   */
  function contractURI() public view returns (string memory uri) {
    uri = string.concat('data:application/json;utf8,', contractMetaData);
  }

  /**
   * @dev check that proxy does not exist OR that the user does not own proxy
   */
  function _shouldBuildProxy(address _user) internal view returns (bool) {
    return _userRegistry[_user] == address(0) || ODProxy(_userRegistry[_user]).OWNER() != _user;
  }

  /**
   * @dev deploys ODProxy for user to interact with protocol
   * updates _proxyRegistry and _userRegistry mappings for new ODProxy
   */
  function _build(address _user) internal virtual returns (address payable _proxy) {
    if (_proxyRegistry[_user] != address(0)) revert NotWallet();
    _proxy = payable(address(new ODProxy(_user)));
    _proxyRegistry[_proxy] = _user;
    _userRegistry[_user] = _proxy;
    emit CreateProxy(_user, address(_proxy));
  }

  /**
   * @dev set or update protocol implementation of SafeManager
   */
  function _setSafeManager(address _safeManager) internal nonZero(_safeManager) {
    safeManager = IODSafeManager(_safeManager);
  }

  /**
   * @dev set or update protocol implementation of NFTRenderer
   */
  function _setNftRenderer(address _nftRenderer) internal nonZero(_nftRenderer) {
    nftRenderer = NFTRenderer(_nftRenderer);
  }

  /**
   * @dev get generated debt and locked collateral of nfv by tokenId
   */
  function _getNfvValue(uint256 _vaultId) internal view returns (uint256, uint256) {
    IODSafeManager.SAFEData memory safeMangerData = safeManager.safeData(_vaultId);
    address safeHandler = safeMangerData.safeHandler;
    if (safeHandler == address(0)) revert ZeroAddress();

    ISAFEEngine.SAFE memory SafeEngineData =
      ISAFEEngine(safeManager.safeEngine()).safes(safeMangerData.collateralType, safeHandler);
    return (SafeEngineData.lockedCollateral, SafeEngineData.generatedDebt);
  }

  /**
   * @dev prevent undesirable frontrun state change during token transferFrom
   * @notice frontrunning that increases the lockedCollateral or decreases the generatedDebt is accepted
   */
  function _enforceStaticState(address _operator, uint256 _tokenId) internal view {
    (uint256 _collateralNow, uint256 _debtNow) = _getNfvValue(_tokenId);
    NFVState memory _nfv = _nfvState[_tokenId];

    if (_collateralNow < _nfv.collateral || _debtNow > _nfv.debt) revert StateViolation();

    if (_allowlist[_operator]) {
      if (block.number < _nfv.lastBlockNumber + blockDelay) revert BlockDelayNotOver();
    } else {
      if (block.timestamp < _nfv.lastBlockTimestamp + timeDelay) revert TimeDelayNotOver();
    }
  }

  /**
   * @dev enforce state before _transfer
   */
  function _transfer(address _from, address _to, uint256 _tokenId) internal override {
    _enforceStaticState(msg.sender, _tokenId);
    super._transfer(_from, _to, _tokenId);
  }

  /**
   * @dev _transfer calls `transferSAFEOwnership` on SafeManager
   * @notice check that NFV receiver has proxy or build
   */
  function _afterTokenTransfer(address _from, address _to, uint256 _tokenId, uint256) internal override {
    require(_to != address(0), 'V721: no burn');
    if (_from != address(0)) {
      address payable proxy;

      if (_shouldBuildProxy(_to)) {
        proxy = _build(_to);
      } else {
        proxy = payable(_userRegistry[_to]);
      }
      IODSafeManager(safeManager).transferSAFEOwnership(_tokenId, address(proxy));
    }
  }
}
