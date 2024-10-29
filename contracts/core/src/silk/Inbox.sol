// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.8.24;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IConversionRateOracle } from "src/interfaces/IConversionRateOracle.sol";
import { XTypes } from "src/libraries/XTypes.sol";
import { IOmniPortal } from "src/interfaces/IOmniPortal.sol";
import { Silk } from "./Silk.sol";

contract Inbox {
    using SafeERC20 for IERC20;

    error InvalidState();
    error Unauthorized();
    error InsufficientFee();
    error InvalidReqHash();
    error TransferFailed();
    error RequestNotFound();
    error RequestCancelled();
    error RequestAlreadyAccepted();
    error RequestAlreadyFulfilled();
    error RequestNotFulfilled();
    error RequestAlreadyPaidOut();

    event Requested(bytes32 indexed guid, address indexed from, Silk.Call call, Silk.Deposit deposit, uint256 fee);
    event Reported(bytes32 indexed guid, address indexed solver);
    event Claimed(bytes32 indexed guid, address indexed to);
    event Cancelled(bytes32 indexed guid);
    event Accepted(bytes32 indexed guid);
    event Rejected(bytes32 indexed guid);

    mapping(address => mapping(bytes4 => bool)) public allowedCalls;
    mapping(address => bool) public allowedSolvers;

    IOmniPortal public omni;
    bytes32 internal _nextGuid;
    mapping(bytes32 guid => Silk.Request) public requests;

    // single trusted outbox, requires namespaced create3 deploy
    address internal immutable outbox;

    constructor(address portal) {
        omni = IOmniPortal(portal);
        _nextGuid = bytes32(uint256(1));
    }

    /// @dev Prototype Entrypoint.request
    function request(Silk.Call calldata call, Silk.TokenDeposit[] calldata deposits) public payable returns (bytes32 guid) {
        guid = nextGuidId();

        // TODO: check deposits, enforce maxes
        uint256 numDeposits = deposits.length;
        if (msg.value > 0) numDeposits++;

        Silk.Deposit memory deposit
        for (uint256 i = 0; i < deposits.length; i++) {
            IERC20(deposit.token).safeTransferFrom(msg.sender, address(this), deposit.amount);
        }



        IERC20(deposit.token).safeTransferFrom(msg.sender, address(this), deposit.amount);

        requests[guid] = Silk.Request({
            from: msg.sender,
            guid: guid,
            timestamp: block.timestamp,
            fee: msg.value,
            call: call,
            deposit: deposit,
            accepted: false,
            rejected: false,
            cancelled: false,
            fulfilled: false,
            fulfilledBy: address(0),
            paidOut: false
        });

        emit Requested(guid, msg.sender, call, deposit, msg.value);
    }

    // static solve fee
    uint256 public solveFee = 0.0005 ether;

    function suggestNativePayment(Silk.Call calldata call, uint64 gasLimit) public view returns (uint256) {
        // cover native value required for dest call
        IConversionRateOracle oracle = IConversionRateOracle(omni.feeOracle());
        uint256 value = call.value * oracle.toNativeRate(call.destChainId) / oracle.CONVERSION_RATE_DENOM();

        return (
            value
            // cover target call
            + omni.feeFor(call.destChainId, call.data, gasLimit)
            // cover Inbox.accpet() gas
            + acceptFee()
            // cover Inbox.report callback xcall fee
            + reportCallbackFee()
            // profit
            + solveFee
        );
    }

    bytes32 internal constant _MAX_BYTES32 = bytes32(type(uint256).max);
    address internal constant _MAX_ADDRESS = address(type(uint160).max);
    uint64 internal constant _REPORT_GAS_LIMIT = 100_000;
    uint256 internal constant _ACCPT_GAS_LIMIT = 100_000;

    function acceptFee() public view returns (uint256) {
        return omni.feeFor(
            omni.chainId(), // this chain id
            abi.encodeCall(this.accept, (_MAX_BYTES32)), // dummy non-zero data
            _ACCPT_GAS_LIMIT
        );
    }

    function accept(bytes32 guid) public payable {
        Silk.Request storage req = requests[guid];

        if (req.guid != guid) revert RequestNotFound();
        if (req.fulfilled) revert RequestAlreadyFulfilled();
        if (req.accepted) revert RequestAlreadyAccepted();
        if (msg.value < suggestFee(req.call, _REPORT_GAS_LIMIT)) revert InsufficientFee();

        req.accepted = true;

        emit Accepted(guid);
    }

    function reportCallbackFee() public view returns (uint256) {
        return omni.feeFor(
            omni.chainId(), // this chain id
            abi.encodeCall(this.report, (_MAX_BYTES32, _MAX_BYTES32, _MAX_ADDRESS)), // dummy non-zero data
            _REPORT_GAS_LIMIT
        );
    }

    function report(bytes32 guid, bytes32 callHash, address solver) public {
        XTypes.MsgContext memory xmsg = omni.xmsg();

        if (xmsg.sender != outbox) revert Unauthorized();

        Silk.Request storage req = requests[guid];

        if (req.call.destChainId != xmsg.sourceChainId) revert Unauthorized();
        if (req.guid != guid) revert RequestNotFound();
        if (hashCall(req.call) != callHash) revert InvalidReqHash();
        if (req.fulfilled) revert RequestAlreadyFulfilled();
        if (req.cancelled) revert RequestCancelled();

        req.fulfilled = true;
        req.fulfilledBy = solver;

        emit Reported(guid, solver);
    }

    function cancel(bytes32 guid) public {
        Silk.Request storage req = requests[guid];

        if (req.guid != guid) revert RequestNotFound();
        if (req.fulfilled) revert RequestAlreadyFulfilled();
        if (req.from != msg.sender) revert Unauthorized();
        if (req.cancelled) revert RequestCancelled();

        if (req.accepted) {
            // if accepted, only allow cancel after 1 day
            if (req.timestamp + 1 days >= block.timestamp) revert Unauthorized();
            // if not explicitly accepted, allow cancel
        }

        req.cancelled = true;

        // return deposit to user
        IERC20(req.deposit.token).safeTransfer(req.from, req.deposit.amount);
        (bool success,) = req.from.call{ value: req.fee }("");
        if (!success) revert TransferFailed();

        emit Cancelled(guid);
    }

    function reject(bytes32 guid) public {
        Silk.Request storage req = requests[guid];

        if (!allowedSolvers[msg.sender]) revert Unauthorized();
        if (req.guid != guid) revert RequestNotFound();
        if (req.fulfilled) revert RequestAlreadyFulfilled();
        if (req.accepted) revert RequestAlreadyAccepted();

        req.rejected = true;

        emit Rejected(guid);
    }

    function claim(bytes32 guid) public {
        Silk.Request storage req = requests[guid];

        if (req.guid != guid) revert RequestNotFound();
        if (!req.fulfilled) revert RequestNotFulfilled();
        if (req.fulfilledBy == address(0)) revert InvalidState();
        if (req.paidOut) revert RequestAlreadyPaidOut();

        address payTo = req.fulfilledBy;

        // transfer deposit to solver
        IERC20(req.deposit.token).safeTransfer(payTo, req.deposit.amount);
        (bool success,) = payTo.call{ value: req.fee }("");
        if (!success) revert TransferFailed();

        req.paidOut = true;

        emit Claimed(guid, payTo);
    }

    function nextGuidId() internal returns (bytes32 guid) {
        assembly {
            guid := sload(_nextGuid.slot)
            sstore(_nextGuid.slot, add(guid, 1))
        }
    }

    function hashCall(Silk.Call storage call) internal pure returns (bytes32) {
        return keccak256(abi.encode(call));
    }
}
