// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {System} from "@latticexyz/world/src/System.sol";

import {TileCommitment} from "codegen/index.sol";
import {Groth16Proof} from "common/Groth16Proof.sol";
import {MoveInputs} from "common/MoveInputs.sol";
import {Signature} from "common/Signature.sol";
import {LibMove} from "libraries/LibMove.sol";
import {LibVerify} from "libraries/LibVerify.sol";

contract MoveSystem is System {
    event NewMove(uint256 hUFrom, uint256 hUTo);

    function move(
        MoveInputs memory moveInputs,
        Groth16Proof memory moveProof,
        Signature memory sig
    ) public {
        LibMove.checkMoveInputs(moveInputs, sig);
        LibVerify.verifyProof(moveInputs, moveProof);

        TileCommitment.deleteRecord({id: moveInputs.hTFrom});
        TileCommitment.set({id: moveInputs.hUFrom, value: true});
        TileCommitment.deleteRecord({id: moveInputs.hTTo});
        TileCommitment.set({id: moveInputs.hUTo, value: true});

        LibMove.updateCityTroopCounts(moveInputs);

        // Should be an offchain table since we're in MUD-land, but fine for now
        emit NewMove(moveInputs.hUFrom, moveInputs.hUTo);
    }

    // /*
    //  * Transfers ownership of one city to its new owner.
    //  */
    // function transferCityOwnership(
    //     uint256 newOwner,
    //     uint256 toCityId,
    //     uint256 ontoSelfOrUnowned
    // ) internal {
    //     // If player is moving onto an enemy's city
    //     if (ontoSelfOrUnowned == 0) {
    //         uint256 enemy = citiesToPlayer[toCityId];

    //         // Pop toCityId from enemyCityList
    //         uint256 lastIndex = playerToCities[enemy].length - 1;
    //         uint256 lastElement = playerToCities[enemy][lastIndex];
    //         playerToCities[enemy][indexOfCity[toCityId]] = lastElement;
    //         playerToCities[enemy].pop();

    //         // The new index of lastElement is where toCityId was
    //         indexOfCity[lastElement] = indexOfCity[toCityId];
    //     }

    //     uint256[] storage cityList = playerToCities[newOwner];
    //     indexOfCity[toCityId] = cityList.length;
    //     cityList.push(toCityId);
    //     playerToCities[newOwner] = cityList;
    //     citiesToPlayer[toCityId] = newOwner;
    // }
}
