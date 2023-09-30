// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IncrementalMerkleTree} from "./IncrementalMerkleTree.sol";

/*
 * Interface for the solidity verifier generated by snarkjs
 */
interface IVerifier {
    function verifyProof(
        uint256[2] memory a,
        uint256[2][2] memory b,
        uint256[2] memory c,
        uint256[13] memory input
    ) external view returns (bool);
}

/*
 * Interface for poseidon hasher where t = 3.
 */
interface IHasherT3 {
    function poseidon(uint256[2] memory input) external pure returns (uint256);
}

struct MoveInputs {
    uint256 root;
    uint256 troopInterval;
    uint256 waterInterval;
    uint256 fromPkHash;
    uint256 fromCityId;
    uint256 toCityId;
    uint256 ontoSelfOrUnowned;
    uint256 takingCity;
    uint256 takingCapital;
    uint256 hUFrom;
    uint256 hUTo;
    uint256 rhoFrom;
    uint256 rhoTo;
}

struct ProofInputs {
    uint256[2] a;
    uint256[2][2] b;
    uint256[2] c;
}

struct SignatureInputs {
    uint8 v;
    bytes32 r;
    bytes32 s;
}

contract NStates is IncrementalMerkleTree {
    IHasherT3 hasherT3 = IHasherT3(0x5FbDB2315678afecb367f032d93F642f64180aa3);
    IVerifier verifierContract =
        IVerifier(0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512);

    event NewMove(uint256 hUFrom, uint256 hUTo);
    event NewLeaf(uint256 h);
    event NewNullifier(uint256 rho);

    address public owner;
    uint256 public numBlocksInTroopUpdate;
    uint256 public numBlocksInWaterUpdate;
    mapping(uint256 => bool) public nullifiers;

    mapping(uint256 => uint256) public citiesToPlayer;
    mapping(uint256 => uint256[]) public playerToCities;
    mapping(uint256 => uint256) public playerToCapital;
    mapping(uint256 => uint256) public capitalToPlayer;

    // A city's index in player's list of cities. Maintained for O(1) deletion
    mapping(uint256 => uint256) public indexOfCity;

    constructor(
        address contractOwner,
        uint8 treeDepth,
        uint256 nothingUpMySleeve,
        uint256 nBlocksInTroopUpdate,
        uint256 nBlocksInWaterUpdate
    ) IncrementalMerkleTree(treeDepth, nothingUpMySleeve) {
        owner = contractOwner;
        numBlocksInTroopUpdate = nBlocksInTroopUpdate;
        numBlocksInWaterUpdate = nBlocksInWaterUpdate;
    }

    /*
     * Functions with this modifier attached can only be called by the contract
     * deployer.
     */
    modifier onlyOwner() {
        require(msg.sender == owner, "Only the owner can call this function");
        _;
    }

    /*
     * Game deployer has the ability to add initial states (leaves) during board
     * initialization.
     */
    function set(uint256 h) public onlyOwner {
        emit NewLeaf(h);
        insertLeaf(h);
    }

    /*
     * Game deployer has the ability to initialize players onto the board.
     */
    function spawn(
        uint256 pkHash,
        uint24 cityId,
        uint256 h,
        uint256 rho
    ) public onlyOwner {
        require(cityId != 0, "City ID must be a non-zero value");
        require(citiesToPlayer[cityId] == 0, "City is already in game");

        set(h);
        nullifiers[rho] = true;

        playerToCapital[pkHash] = cityId;
        capitalToPlayer[cityId] = pkHash;

        citiesToPlayer[cityId] = pkHash;
        playerToCities[pkHash] = [cityId];
        indexOfCity[cityId] = 0;

        emit NewNullifier(rho);
    }

    /*
     * Accepts new states for tiles involved in move. Nullifies old states.
     * Moves must operate on states that aren't nullified AND carry a ZKP
     * anchored to a historical merkle root to be accepted.
     */
    function move(
        MoveInputs memory moveInputs,
        ProofInputs memory moveProof,
        SignatureInputs memory sig
    ) public {
        require(rootHistory[moveInputs.root], "Root must be in root history");
        require(
            currentTroopInterval() >= moveInputs.troopInterval,
            "Move is too far into the future, change currentTroopInterval value"
        );
        require(
            currentWaterInterval() >= moveInputs.waterInterval,
            "Move is too far into the future, change currentWaterInterval value"
        );
        require(
            moveInputs.fromPkHash == citiesToPlayer[moveInputs.fromCityId],
            "Must move from a city that you own"
        );
        require(
            checkOntoSelfOrUnowned(
                moveInputs.fromPkHash,
                moveInputs.toCityId,
                moveInputs.ontoSelfOrUnowned
            ),
            "Value of ontoSelfOrUnowned is incorrect"
        );
        require(
            !nullifiers[moveInputs.rhoFrom] && !nullifiers[moveInputs.rhoTo],
            "Move has already been made"
        );
        require(
            getSigner(moveInputs.hUFrom, moveInputs.hUTo, sig) == owner,
            "Enclave signature is incorrect"
        );
        require(
            verifierContract.verifyProof(
                moveProof.a,
                moveProof.b,
                moveProof.c,
                toArray(moveInputs)
            ),
            "Invalid move proof"
        );

        nullifiers[moveInputs.rhoFrom] = true;
        nullifiers[moveInputs.rhoTo] = true;

        insertLeaf(moveInputs.hUFrom);
        insertLeaf(moveInputs.hUTo);

        if (moveInputs.takingCity == 1) {
            transferCityOwnership(
                moveInputs.fromPkHash,
                moveInputs.toCityId,
                moveInputs.ontoSelfOrUnowned
            );
        } else if (moveInputs.takingCapital == 1) {
            uint256 enemy = capitalToPlayer[moveInputs.toCityId];

            while (playerToCities[enemy].length > 0) {
                uint256 lastIndex = playerToCities[enemy].length - 1;
                transferCityOwnership(
                    moveInputs.fromPkHash,
                    playerToCities[enemy][lastIndex],
                    0
                );
            }

            playerToCapital[enemy] = 0;
            capitalToPlayer[moveInputs.toCityId] = 0;
        }

        emit NewMove(moveInputs.hUFrom, moveInputs.hUTo);
        emit NewLeaf(moveInputs.hUFrom);
        emit NewLeaf(moveInputs.hUTo);
        emit NewNullifier(moveInputs.rhoFrom);
        emit NewNullifier(moveInputs.rhoTo);
    }

    /*
     * Helper function for move(). Checks if public signal ontoSelfOrUnowned is
     * set correctly. ontoSelfOrUnowned is used in the ZKP, but must be
     * checked onchain.
     */
    function checkOntoSelfOrUnowned(
        uint256 fromPkHash,
        uint256 toCityId,
        uint256 ontoSelfOrUnowned
    ) internal view returns (bool) {
        uint256 toCityOwner = citiesToPlayer[toCityId];
        if (toCityOwner == fromPkHash || toCityOwner == 0) {
            return ontoSelfOrUnowned == 1;
        }
        return ontoSelfOrUnowned == 0;
    }

    /*
     * Transfers ownership of one city to its new owner.
     */
    function transferCityOwnership(
        uint256 newOwner,
        uint256 toCityId,
        uint256 ontoSelfOrUnowned
    ) internal {
        // If player is moving onto an enemy's city
        if (ontoSelfOrUnowned == 0) {
            uint256 enemy = citiesToPlayer[toCityId];

            // Pop toCityId from enemyCityList
            uint256 lastIndex = playerToCities[enemy].length - 1;
            uint256 lastElement = playerToCities[enemy][lastIndex];
            playerToCities[enemy][indexOfCity[toCityId]] = lastElement;
            playerToCities[enemy].pop();

            // The new index of lastElement is where toCityId was
            indexOfCity[lastElement] = indexOfCity[toCityId];
        }

        uint256[] storage cityList = playerToCities[newOwner];
        indexOfCity[toCityId] = cityList.length;
        cityList.push(toCityId);
        playerToCities[newOwner] = cityList;
        citiesToPlayer[toCityId] = newOwner;
    }

    /*
     * Number of leaves in the merkle tree. Value is roughly double the number
     * of historic accepted moves.
     */
    function getNumLeaves() public view returns (uint256) {
        return nextLeafIndex;
    }

    /*
     * Compute poseidon hash of two child hashes.
     */
    function _hashLeftRight(
        uint256 l,
        uint256 r
    ) internal view override returns (uint256) {
        return hasherT3.poseidon([l, r]);
    }

    /*
     * Troop updates are counted in intervals, where the current interval is
     * the current block height divided by interval length.
     */
    function currentTroopInterval() public view returns (uint256) {
        return block.number / numBlocksInTroopUpdate;
    }

    /*
     * Same as troop updates, but how when players lose troops on water tiles.
     */
    function currentWaterInterval() public view returns (uint256) {
        return block.number / numBlocksInWaterUpdate;
    }

    /*
     * From a signature obtain the address that signed. This should
     * be the enclave's address whenever a player submits a move.
     */
    function getSigner(
        uint256 hUFrom,
        uint256 hUTo,
        SignatureInputs memory sig
    ) public pure returns (address) {
        bytes32 hash = keccak256(abi.encode(hUFrom, hUTo));
        bytes32 prefixedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)
        );
        return ecrecover(prefixedHash, sig.v, sig.r, sig.s);
    }

    function toArray(
        MoveInputs memory moveInputs
    ) internal pure returns (uint256[13] memory) {
        return [
            moveInputs.root,
            moveInputs.troopInterval,
            moveInputs.waterInterval,
            moveInputs.fromPkHash,
            moveInputs.fromCityId,
            moveInputs.toCityId,
            moveInputs.ontoSelfOrUnowned,
            moveInputs.takingCity,
            moveInputs.takingCapital,
            moveInputs.hUFrom,
            moveInputs.hUTo,
            moveInputs.rhoFrom,
            moveInputs.rhoTo
        ];
    }
}
