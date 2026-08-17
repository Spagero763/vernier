// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IRateAttestor} from "../interfaces/IRateAttestor.sol";

/// Operator set that answers one question: is a pool's rate source still telling the
/// truth. Follows the ECDSA attestation shape of EigenLayer's Hello World sample, where
/// operators sign a message and the service checks the signatures carry enough weight.
///
/// Weights are set here rather than read from a stake registry. In production they come
/// from the operator's delegated stake and registration flows through EigenLayer core;
/// swapping the source of `operatorWeight` is the only change that requires.
///
/// The service can only ever answer "not sound", which the hook treats as a reason to
/// stop correcting. It cannot move a price, so a captured operator set degrades the pool
/// to an ordinary AMM and can do nothing worse.
contract RateAttestationService is IRateAttestor {
    error NotOwner();
    error UnknownOperator(address operator);
    error SignersOutOfOrder();
    error QuorumNotMet(uint256 weight, uint256 required);
    error StaleNonce(uint64 submitted, uint64 current);
    error LengthMismatch();
    error InvalidQuorum();

    struct Attestation {
        bool sound;
        uint64 at;
        uint64 nonce;
    }

    address public immutable owner;

    uint256 public totalWeight;
    uint16 public quorumBps;
    uint64 public freshnessWindow;

    mapping(address => uint256) public operatorWeight;
    mapping(PoolId => Attestation) public attestationOf;

    event OperatorSet(address indexed operator, uint256 weight);
    event QuorumSet(uint16 quorumBps, uint64 freshnessWindow);
    event Attested(PoolId indexed poolId, bool sound, uint64 nonce, uint256 weight);

    constructor(uint16 quorumBps_, uint64 freshnessWindow_) {
        owner = msg.sender;
        _setQuorum(quorumBps_, freshnessWindow_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function setQuorum(uint16 quorumBps_, uint64 freshnessWindow_) external onlyOwner {
        _setQuorum(quorumBps_, freshnessWindow_);
    }

    function setOperator(address operator, uint256 weight) external onlyOwner {
        totalWeight = totalWeight - operatorWeight[operator] + weight;
        operatorWeight[operator] = weight;
        emit OperatorSet(operator, weight);
    }

    /// Signers must be strictly ascending, which both rejects duplicates and keeps the
    /// weight tally honest without a second pass or a seen-set.
    function submitAttestation(
        PoolId id,
        bool sound,
        uint64 nonce,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external {
        if (signers.length != signatures.length) revert LengthMismatch();

        Attestation memory current = attestationOf[id];
        if (nonce <= current.nonce) revert StaleNonce(nonce, current.nonce);

        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(attestationDigest(id, sound, nonce));

        uint256 weight;
        address previous;

        for (uint256 i = 0; i < signers.length; i++) {
            address signer = signers[i];
            if (signer <= previous) revert SignersOutOfOrder();
            previous = signer;

            uint256 w = operatorWeight[signer];
            if (w == 0) revert UnknownOperator(signer);
            if (ECDSA.recover(digest, signatures[i]) != signer) revert UnknownOperator(signer);

            weight += w;
        }

        uint256 required = (totalWeight * quorumBps) / 10_000;
        if (weight < required) revert QuorumNotMet(weight, required);

        attestationOf[id] = Attestation({sound: sound, at: uint64(block.timestamp), nonce: nonce});
        emit Attested(id, sound, nonce, weight);
    }

    /// Chain id and this address are in the digest so an attestation cannot be replayed
    /// onto another deployment or another chain.
    function attestationDigest(PoolId id, bool sound, uint64 nonce) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), id, sound, nonce));
    }

    /// Silence is not an accusation. With no attestation, or one that has gone stale, the
    /// hook is left to its own bounds rather than having corrections withheld forever by
    /// an operator set that simply stopped reporting.
    function isSound(PoolId id) external view returns (bool) {
        Attestation memory a = attestationOf[id];
        if (a.at == 0) return true;
        if (block.timestamp - a.at > freshnessWindow) return true;
        return a.sound;
    }

    function _setQuorum(uint16 quorumBps_, uint64 freshnessWindow_) internal {
        if (quorumBps_ == 0 || quorumBps_ > 10_000) revert InvalidQuorum();
        quorumBps = quorumBps_;
        freshnessWindow = freshnessWindow_;
        emit QuorumSet(quorumBps_, freshnessWindow_);
    }
}
