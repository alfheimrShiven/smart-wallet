// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.12;

import { IAccountLock } from "../interface/IAccountLock.sol";
import { Guardian } from "contracts/prebuilts/account/utils/Guardian.sol";
import { AccountGuardian } from "contracts/prebuilts/account/utils/AccountGuardian.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MockV3Aggregator } from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";
import { MockLinkToken } from "@chainlink/contracts/src/v0.8/mocks/MockLinkToken.sol";
import { AutomationCompatibleInterface } from "@chainlink/contracts/src/v0.8/interfaces/automation/AutomationCompatibleInterface.sol";
// import { KeeperRegistryBase2_0Mock } from "@chainlink/contracts/src/v0.8/mocks/KeeperRegistryBase2_0Mock.sol";
// import { KeeperRegistry2_0Mock } from "@chainlink/contracts/src/v0.8/mocks/KeeperRegistry2_0Mock.sol";
// import { KeeperRegistrar2_0Mock } from "@chainlink/contracts/src/v0.8/mocks/KeeperRegistrar2_0Mock.sol";
import "forge-std/console.sol";

struct RegistrationParams {
    string name;
    bytes encryptedEmail;
    address upkeepContract;
    uint32 gasLimit;
    address adminAddress;
    uint8 triggerType;
    bytes checkData;
    bytes triggerConfig;
    bytes offchainConfig;
    uint96 amount;
}

contract AccountLock is IAccountLock {
    Guardian public guardianContract;
    uint8 public constant DECIMAL = 8;
    int256 public constant INITIAL_LINK_PRICE = 2000e8;
    int256 public constant INITIAL_GAS_PRICE = 2e8;
    uint96 public constant FUND_UPKEEP_LINK_TOKEN = 5e18;
    uint256 public constant LOCK_REQUEST_TIME_TO_EVALUATION = 604800; // 7 days
    address[] public lockedAccounts;
    mapping(address => bytes32) private accountToLockRequest;
    mapping(address => bytes32) private accountToUnLockRequest;
    // mapping(bytes32 => uint256) private lockRequestToCreationTime;
    // mapping(bytes32 => bool) private accountRequestConcensusEvaluationStatus;
    mapping(bytes32 => bool) private unlockAccountRequestConcensusEvaluationStatus;
    mapping(bytes32 => address[]) public requestToGuardiansSigned;
    mapping(bytes32 => mapping(address => bytes)) public lockRequestToGuardianToSignature;
    mapping(bytes32 => mapping(address => bytes)) public unLockRequestToGuardianToSignature;
    mapping(bytes32 => mapping(address => bool)) lockRequestToGuardianToSignatureValid;
    mapping(bytes32 => mapping(address => bool)) unLockRequestToGuardianToSignatureValid;

    ///////////////////////////////////////////
    ///// MOCKS  //////////////////////////////
    // (TODO: To be moved to a script file)//
    //////////////////////////////////////////

    // MockLinkToken mockLinkToken = new MockLinkToken();

    // MockV3Aggregator linkNativePriceFeed = new MockV3Aggregator(DECIMAL, INITIAL_LINK_PRICE);

    // MockV3Aggregator fastGasPriceFeed = new MockV3Aggregator(DECIMAL, INITIAL_LINK_PRICE);

    // KeeperRegistryBase2_0Mock keeperRegistryBase =
    //     new KeeperRegistryBase2_0Mock(
    //         KeeperRegistryBase2_0Mock.Mode.DEFAULT,
    //         address(mockLinkToken),
    //         address(linkNativePriceFeed),
    //         address(fastGasPriceFeed)
    //     );

    // KeeperRegistry2_0Mock chainlinkKeeperRegistry = new KeeperRegistry2_0Mock(keeperRegistryBase);

    // KeeperRegistrar2_0Mock chainlinkKeeperRegistrar =
    //     new KeeperRegistrar2_0Mock(
    //         address(mockLinkToken),
    //         KeeperRegistrar2_0Mock.AutoApproveType.ENABLED_ALL,
    //         type(uint16).max,
    //         address(chainlinkKeeperRegistry),
    //         FUND_UPKEEP_LINK_TOKEN
    //     );

    constructor(Guardian _guardian) {
        guardianContract = _guardian;
    }

    modifier onlyVerifiedAccountGuardian(address account) {
        address accountGuardian = guardianContract.getAccountGuardian(account);

        if (!AccountGuardian(accountGuardian).isAccountGuardian(msg.sender)) {
            revert NotAGuardian(msg.sender);
        }
        _;
    }

    /////////////////////////////////
    /////// External Func ///////////
    /////////////////////////////////

    function createLockRequest(address account) external onlyVerifiedAccountGuardian(account) returns (bytes32) {
        /**
         * Step 1: check if the msg.sender is the guardian of the smartWallet account
         *
         * Step 2: Check the current status of the smart wallet (locked/unlocked) and if unlocked, check if any exisiting lock request exists. Revert if wallet is already locked or a lock req. exists
         *
         * Step 3: Create lock request (Encode -> Hashing)
         *
         * Step 4: Send request to all other guardians of this smart account
         **/

        if (_isLocked(account)) {
            revert AccountAlreadyLocked(account);
        }

        if (activeLockRequestExists(account)) {
            revert ActiveLockRequestFound();
        }

        bytes32 lockRequestHash = keccak256(abi.encodeWithSignature("_lockAccount(address account)", account));
        bytes32 ethSignedLockRequestHash = ECDSA.toEthSignedMessageHash(lockRequestHash);

        accountToLockRequest[account] = ethSignedLockRequestHash;
        return ethSignedLockRequestHash;
    }

    function createUnLockRequest(address account) external onlyVerifiedAccountGuardian(account) returns (bytes32) {
        if (!_isLocked(account)) {
            revert AccountAlreadyUnLocked(account);
        }

        if (activeUnLockRequestExists(account)) {
            revert ActiveUnLockRequestFound();
        }

        bytes32 unLockRequestHash = keccak256(abi.encodeWithSignature("_unLockAccount(address account)", account));

        bytes32 ethSignedUnLockRequestHash = ECDSA.toEthSignedMessageHash(unLockRequestHash);

        accountToUnLockRequest[account] = ethSignedUnLockRequestHash;

        unlockAccountRequestConcensusEvaluationStatus[ethSignedUnLockRequestHash] = false;

        return ethSignedUnLockRequestHash;
    }

    function recordSignatureOnLockRequest(bytes32 lockRequest, bytes calldata signature) external {
        address guardian = msg.sender;

        if (!guardianContract.isVerifiedGuardian(guardian)) {
            revert NotAGuardian(guardian);
        }

        lockRequestToGuardianToSignature[lockRequest][guardian] = signature;
        requestToGuardiansSigned[lockRequest].push(guardian);
    }

    function recordSignatureOnUnLockRequest(bytes32 unLockRequest, bytes calldata signature) external {
        address guardian = msg.sender;

        if (!guardianContract.isVerifiedGuardian(guardian)) {
            revert NotAGuardian(guardian);
        }

        unLockRequestToGuardianToSignature[unLockRequest][guardian] = signature;
        requestToGuardiansSigned[unLockRequest].push(guardian);
    }

    //TODO: Add trigger to this function once lock request is created, using Chainlink Time based automation (Ref: https://docs.chain.link/chainlink-automation/overview/getting-started)
    function accountRequestConcensusEvaluation(
        address account
    ) public onlyVerifiedAccountGuardian(account) returns (bool) {
        bytes32 request;

        if (_isLocked(account)) {
            request = accountToUnLockRequest[account];
        } else {
            request = accountToLockRequest[account];
        }

        if (request == bytes32(0)) {
            revert NoActiveRequestFoundForAccount(account);
        }

        uint256 validGuardianSignatures = 0;
        address accountGuardian = guardianContract.getAccountGuardian(account);
        address[] memory guardians = AccountGuardian(accountGuardian).getAllGuardians();
        uint256 guardianCount = guardians.length;

        address[] memory guardiansWhoSigned = requestToGuardiansSigned[request];

        for (uint256 g = 0; g < guardiansWhoSigned.length; g++) {
            address guardian = guardiansWhoSigned[g];
            bytes memory guardianSignature;

            if (_isLocked(account)) {
                guardianSignature = unLockRequestToGuardianToSignature[request][guardian];
            } else {
                guardianSignature = lockRequestToGuardianToSignature[request][guardian];
            }

            address recoveredGuardian = _recoverSigner(request, guardianSignature);
            console.log("Recovered guardian", recoveredGuardian);

            if (recoveredGuardian == guardian) {
                // case: signature is valid
                if (_isLocked(account)) {
                    // checking which request's mapping to alter: lock or unlock request
                    unLockRequestToGuardianToSignatureValid[request][guardian] = true;
                } else {
                    lockRequestToGuardianToSignatureValid[request][guardian] = true;
                }
                validGuardianSignatures++;
            } else {
                // case: signature is not valid
                if (_isLocked(account)) {
                    // checking which request's mapping to alter: lock or unlock request
                    unLockRequestToGuardianToSignatureValid[request][guardian] = false;
                } else {
                    lockRequestToGuardianToSignatureValid[request][guardian] = false;
                }
            }
        }

        // accountRequestConcensusEvaluationStatus[request] = true;

        if (validGuardianSignatures > (guardianCount / 2)) {
            if (_isLocked(account)) {
                _unLockAccount(payable(account));
            } else {
                _lockAccount(payable(account));
            }
            emit RequestConcensusAchieved(account);
            return true;
        } else {
            emit RequestConcensusCouldNotBeAchieved(account);
            return false;
        }
    }

    function addLockAccountToList(address account) public {
        lockedAccounts.push(account);
    }

    /////////////////////////////////
    /////// View Func //////////////
    ////////////////////////////////
    function activeLockRequestExists(address account) public view returns (bool) {
        if (accountToLockRequest[account] != bytes32(0)) {
            return true;
        } else {
            return false;
        }
    }

    function activeUnLockRequestExists(address account) public view returns (bool) {
        if (accountToUnLockRequest[account] != bytes32(0)) {
            return true;
        } else {
            return false;
        }
    }

    /// @dev Returns all lock request for a guardian
    function getLockRequests() external view returns (bytes32[] memory) {
        if (!guardianContract.isVerifiedGuardian(msg.sender)) {
            revert NotAGuardian(msg.sender);
        }

        address[] memory accounts = guardianContract.getAccountsTheGuardianIsGuarding(msg.sender);

        bytes32[] memory lockRequests = new bytes32[](accounts.length); // predefining the array length because it's stored in memory.

        // get lock req. of each account the guardian is guarding and return
        for (uint256 a = 0; a < accounts.length; a++) {
            lockRequests[a] = accountToLockRequest[accounts[a]];
        }

        return lockRequests;
    }

    /// @dev Returns all lock request for a guardian
    function getUnLockRequests() external view returns (bytes32[] memory) {
        if (!guardianContract.isVerifiedGuardian(msg.sender)) {
            revert NotAGuardian(msg.sender);
        }

        address[] memory accounts = guardianContract.getAccountsTheGuardianIsGuarding(msg.sender);

        bytes32[] memory unLockRequests = new bytes32[](accounts.length); // predefining the array length because it's stored in memory.

        // get lock req. of each account the guardian is guarding and return
        for (uint256 a = 0; a < accounts.length; a++) {
            unLockRequests[a] = accountToUnLockRequest[accounts[a]];
        }

        return unLockRequests;
    }

    /////////////////////////////////
    //// Internal Func /////////////
    /////////////////////////////////

    function _isLocked(address account) internal view returns (bool) {
        for (uint256 a = 0; a < lockedAccounts.length; a++) {
            if (lockedAccounts[a] == account) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Will lock all account assets and transactions
     * @param account The account to be locked
     */
    function _lockAccount(address payable account) internal {
        (bool success, ) = account.call(abi.encodeWithSignature("setPaused(bool)", true));

        require(success, "Locking account failed");
    }

    /**
     * @notice Will unlock all account assets and transactions
     * @param account The account to be unlocked
     */
    function _unLockAccount(address payable account) internal {
        (bool success, ) = account.call(abi.encodeWithSignature("setPaused(bool)", false));

        require(success, "Locking account failed");
    }

    function _recoverSigner(bytes32 lockRequest, bytes memory guardianSignature) internal pure returns (address) {
        // verify
        address recoveredGuardian = ECDSA.recover(lockRequest, guardianSignature);

        return recoveredGuardian;
    }
}
