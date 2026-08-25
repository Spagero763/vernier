// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// Hands a visitor both demo tokens in one transaction. Four wallet prompts to reach a
/// two minute demo is enough friction to lose people partway, and a run that stops
/// halfway leaves an account that looks funded but cannot trade.
contract Faucet {
    IMintable public immutable quote;
    IMintable public immutable yieldToken;

    uint256 public constant AMOUNT = 1_000e18;

    event Claimed(address indexed to, uint256 amount);

    constructor(address quote_, address yieldToken_) {
        quote = IMintable(quote_);
        yieldToken = IMintable(yieldToken_);
    }

    function claim() external {
        quote.mint(msg.sender, AMOUNT);
        yieldToken.mint(msg.sender, AMOUNT);
        emit Claimed(msg.sender, AMOUNT);
    }
}
