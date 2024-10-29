// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.8.24;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ConfLevel } from "src/libraries/ConfLevel.sol";
import { IOmniPortal } from "src/interfaces/IOmniPortal.sol";
import { Silk } from "./Silk.sol";
import { Inbox } from "./Inbox.sol";

contract Outbox is Ownable {
    using SafeERC20 for IERC20;

    mapping(address => mapping(bytes4 => bool)) public allowedCalls;
    mapping(address => bool) public allowedSolvers;

    IOmniPortal public omni;

    // single trusted inbox, requires namespaced create3 deploy
    address public inbox;

    bytes32 internal constant _MAX_BYTES32 = bytes32(type(uint256).max);
    address internal constant _MAX_ADDRESS = address(type(uint160).max);
    uint64 internal constant _REPORT_GAS_LIMIT = 100_000;

    error Unauthorized();
    error InsufficientFee();
    error CallFailed();
    error CallNotAllowed();

    constructor(address portal, address owner) Ownable(owner) {
        omni = IOmniPortal(portal);
    }

    struct ExecPreReq {
        address token;
        uint256 amount;
    }

    error InvalidPreReqs();

    function execute(
        address creditTo,
        uint64 srcChainId,
        bytes32 srcGuid,
        ExecPreReq[] calldata prereqs,
        Silk.Call calldata call
    ) external payable {
        if (!allowedSolvers[msg.sender]) revert Unauthorized();
        if (call.destChainId != uint64(block.chainid)) revert Unauthorized();

        uint256[] memory prereqBalances = new uint256[prereqs.length];

        for (uint256 i = 0; i < prereqs.length; i++) {
            prereqBalances[i] = IERC20(prereqs[i].token).balanceOf(address(this));

            // transfer from solver to outbox
            IERC20(prereqs[i].token).safeTransferFrom(msg.sender, address(this), prereqs[i].amount);

            // allow target to spend
            IERC20(prereqs[i].token).safeApprove(call.target, prereqs[i].amount);
        }

        uint256 reportFee = reportCallbackFee(srcChainId);
        if (msg.value != reportFee + call.value) revert InsufficientFee();

        // exec calls
        if (!allowedCalls[call.target][bytes4(call.data)]) revert CallNotAllowed();
        (bool success,) = call.target.call{ value: call.value }(call.data);
        if (!success) revert CallFailed();

        omni.xcall{ value: reportFee }(
            srcChainId,
            ConfLevel.Finalized,
            inbox,
            abi.encodeCall(Inbox.report, (srcGuid, hashCall(call), creditTo)),
            _REPORT_GAS_LIMIT
        );

        for (uint256 i = 0; i < prereqs.length; i++) {
            // assert balance unchanged
            if (IERC20(prereqs[i].token).balanceOf(address(this)) != prereqBalances[i]) revert InvalidPreReqs();
        }

        emit Executed(srcChainId, srcGuid, creditTo, call);
    }

    function reportCallbackFee(uint64 originChainId) public view returns (uint256) {
        return omni.feeFor(
            originChainId,
            abi.encodePacked(_MAX_BYTES32, _MAX_BYTES32, _MAX_ADDRESS), // dummy non-zero data
            _REPORT_GAS_LIMIT
        );
    }

    function hashCall(Silk.Call calldata call) internal pure returns (bytes32) {
        return keccak256(abi.encode(call));
    }
}
