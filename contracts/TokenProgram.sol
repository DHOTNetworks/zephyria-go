// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title TokenProgram
 * @dev A system contract that manages SPL-like Token Mints and ATAs.
 * This contract is special-cased by the Aquarius VM for state sharding.
 */
contract TokenProgram {
    // Metadata (Stored in Proxy Storage)
    string public name;
    string public symbol;
    uint8 public decimals;

    // Events
    event Transfer(address indexed from, address indexed to, uint256 value);
    event MintCreated(address indexed tokenAddress, uint8 decimals, address indexed creator);

    /**
     * @dev Transfer tokens between users.
     * Intercepted by VM to redirect storage reads/writes to Data Shards (ATAs).
     */
    function transfer(address to, uint256 amount) external returns (bool) {
        address from = msg.sender;
        require(to != address(0), "Transfer to zero address");

        uint256 fromBalance;
        uint256 toBalance;

        // The VM intercepts SLOAD(from) and SLOAD(to) 
        // to read from ATA(from, this) and ATA(to, this)
        assembly {
            fromBalance := sload(from)
        }

        require(fromBalance >= amount, "Insufficient balance");

        fromBalance -= amount;
        toBalance += amount; // We assume 0 if not set, but sload handles it

        // Get toBalance (Intercepted)
        assembly {
            toBalance := sload(to)
            toBalance := add(toBalance, amount)
            
            // The VM intercepts SSTORE(from) and SSTORE(to)
            // to write to ATA(from, this) and ATA(to, this)
            sstore(from, fromBalance)
            sstore(to, toBalance)
        }

        emit Transfer(from, to, amount);
        return true;
    }

    /**
     * @dev Core ERC20 compatibility.
     * Intercepted by VM.
     */
    function balanceOf(address owner) external view returns (uint256 bal) {
        assembly {
            bal := sload(owner)
        }
    }

    /**
     * @dev Create a new Token Mint.
     * Deploys a minimal proxy (EIP-1167) that delegates to this contract.
     */
    function createToken(string memory _name, string memory _symbol, uint8 _decimals) external returns (address tokenAddress) {
        // Dynamic construction logic in assembly to ensure it points to *this* contract
        bytes20 targetBytes = bytes20(address(this));
        
        assembly {
            let clone := mload(0x40)
            // Init Code Logic + Proxy Runtime Logic
            mstore(clone, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone, 0x14), targetBytes)
            mstore(add(clone, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            tokenAddress := create(0, clone, 0x37)
        }
        
        if (tokenAddress == address(0)) revert("FAIL_CREATE");
        
        // Stage 1: Initialize
        TokenProgram(tokenAddress).initialize(msg.sender, 1000000 * (10 ** uint256(_decimals)));
        
        // Stage 2: Metadata
        TokenProgram(tokenAddress).initMetadata(_name, _symbol, _decimals);
        
        emit MintCreated(tokenAddress, _decimals, msg.sender);
    }

    function initMetadata(string memory _name, string memory _symbol, uint8 _decimals) external {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function initialize(address owner, uint256 amount) external {
        assembly {
            sstore(owner, amount)
        }
    }
}
