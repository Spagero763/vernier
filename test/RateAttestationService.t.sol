// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {RateAttestationService} from "../src/avs/RateAttestationService.sol";

contract RateAttestationServiceTest is Test {
    RateAttestationService internal service;
    PoolId internal id = PoolId.wrap(keccak256("pool"));

    uint256 internal keyA;
    uint256 internal keyB;
    uint256 internal keyC;
    address internal opA;
    address internal opB;
    address internal opC;

    function setUp() public {
        service = new RateAttestationService(6667, 1 hours);

        (opA, keyA) = makeAddrAndKey("operatorA");
        (opB, keyB) = makeAddrAndKey("operatorB");
        (opC, keyC) = makeAddrAndKey("operatorC");

        service.setOperator(opA, 100);
        service.setOperator(opB, 100);
        service.setOperator(opC, 100);
    }

    function test_quorumOfOperatorsCanMarkRateUnsound() public {
        _attest(false, 1);

        assertFalse(service.isSound(id), "attested unsound rate should read unsound");
    }

    function test_belowQuorumIsRejected() public {
        (address[] memory signers, uint256[] memory keys) = _one();
        bytes[] memory sigs = _sign(false, 1, signers, keys);

        vm.expectRevert(abi.encodeWithSelector(RateAttestationService.QuorumNotMet.selector, 100, 200));
        service.submitAttestation(id, false, 1, signers, sigs);
    }

    function test_staleAttestationFallsBackToSound() public {
        _attest(false, 1);
        assertFalse(service.isSound(id));

        vm.warp(block.timestamp + 2 hours);
        assertTrue(service.isSound(id), "an operator set that stops reporting must not withhold forever");
    }

    function test_replayedNonceIsRejected() public {
        _attest(false, 1);

        (address[] memory signers, uint256[] memory keys) = _three();
        bytes[] memory sigs = _sign(false, 1, signers, keys);

        vm.expectRevert(abi.encodeWithSelector(RateAttestationService.StaleNonce.selector, uint64(1), uint64(1)));
        service.submitAttestation(id, false, 1, signers, sigs);
    }

    function test_duplicateSignerCannotPadTheQuorum() public {
        address[] memory signers = new address[](3);
        uint256[] memory keys = new uint256[](3);
        signers[0] = opA;
        signers[1] = opA;
        signers[2] = opA;
        keys[0] = keyA;
        keys[1] = keyA;
        keys[2] = keyA;

        bytes[] memory sigs = _sign(false, 1, signers, keys);

        vm.expectRevert(RateAttestationService.SignersOutOfOrder.selector);
        service.submitAttestation(id, false, 1, signers, sigs);
    }

    function test_signatureFromNonOperatorIsRejected() public {
        (address rogue, uint256 rogueKey) = makeAddrAndKey("rogue");

        address[] memory signers = new address[](1);
        uint256[] memory keys = new uint256[](1);
        signers[0] = rogue;
        keys[0] = rogueKey;

        bytes[] memory sigs = _sign(false, 1, signers, keys);

        vm.expectRevert(abi.encodeWithSelector(RateAttestationService.UnknownOperator.selector, rogue));
        service.submitAttestation(id, false, 1, signers, sigs);
    }

    function test_attestationCannotBeReplayedOntoAnotherDeployment() public {
        RateAttestationService other = new RateAttestationService(6667, 1 hours);
        other.setOperator(opA, 100);
        other.setOperator(opB, 100);
        other.setOperator(opC, 100);

        (address[] memory signers, uint256[] memory keys) = _three();
        bytes[] memory sigs = _sign(false, 1, signers, keys);

        vm.expectRevert();
        other.submitAttestation(id, false, 1, signers, sigs);
    }

    function test_soundAgainAfterRecovery() public {
        _attest(false, 1);
        assertFalse(service.isSound(id));

        _attest(true, 2);
        assertTrue(service.isSound(id), "operators should be able to clear the flag");
    }

    function _attest(bool sound, uint64 nonce) internal {
        (address[] memory signers, uint256[] memory keys) = _three();
        service.submitAttestation(id, sound, nonce, signers, _sign(sound, nonce, signers, keys));
    }

    function _sign(bool sound, uint64 nonce, address[] memory signers, uint256[] memory keys)
        internal
        view
        returns (bytes[] memory sigs)
    {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(service.attestationDigest(id, sound, nonce));
        sigs = new bytes[](signers.length);
        for (uint256 i = 0; i < signers.length; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], digest);
            sigs[i] = abi.encodePacked(r, s, v);
        }
    }

    function _three() internal view returns (address[] memory signers, uint256[] memory keys) {
        signers = new address[](3);
        keys = new uint256[](3);
        (signers[0], keys[0]) = (opA, keyA);
        (signers[1], keys[1]) = (opB, keyB);
        (signers[2], keys[2]) = (opC, keyC);
        _sortByAddress(signers, keys);
    }

    function _one() internal view returns (address[] memory signers, uint256[] memory keys) {
        signers = new address[](1);
        keys = new uint256[](1);
        (signers[0], keys[0]) = (opA, keyA);
    }

    function _sortByAddress(address[] memory signers, uint256[] memory keys) internal pure {
        for (uint256 i = 1; i < signers.length; i++) {
            for (uint256 j = i; j > 0 && signers[j] < signers[j - 1]; j--) {
                (signers[j], signers[j - 1]) = (signers[j - 1], signers[j]);
                (keys[j], keys[j - 1]) = (keys[j - 1], keys[j]);
            }
        }
    }
}
