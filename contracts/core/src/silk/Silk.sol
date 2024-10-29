// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.8.24;

// we might need some time of API for frontends to interact with toK

// could do alternative mempool for EIP-712 signed requests
// could allow contract verification of requests via EIP-1271

library Silk {
    struct Request {
        bytes32 guid;           // unique per source
        address from;           // the requesting user addr
        uint256 timestamp;      // when the request was made
        Deposit[] deposits;     // erc20 / native deposits backing the call
        Call call;              // call to execute
        bool accepted;          // whether the request has been accepted by a solver
        bool rejected;          // whether the request has been rejected by a solver
        bool cancelled;         // whether the request has been canceled by the user
        bool fulfilled;         // whether the request has been fulfilled at dest
        address fulfilledBy;    // address that solved the request
        bool paidOut;           // whether the request has been paid out to fulfilledBy
    }

    struct Call {
        uint64 destChainId;
        uint256 value;
        address target;
        bytes data;
    }

    struct Deposit {
        address token; // token addr == 0 for native
        bool isNative; // true if native token
        uint256 amount;
    }

    struct TokenDeposit {
        address token;
        uint256 amount;
    }

    struct ExecPreReq {
        address token;
        uint256 amount;
    }
}
