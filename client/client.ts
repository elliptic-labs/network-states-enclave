import readline from "readline";
import { ethers } from "ethers";
import { io, Socket } from "socket.io-client";
import dotenv from "dotenv";
dotenv.config({ path: "../.env" });
import { ServerToClientEvents, ClientToServerEvents } from "../enclave/socket";
import { Player, Tile, Board, Location, Utils } from "../game";

/*
 * Conditions depend on which player is currently active.
 */
const PLAYER_SYMBOL: string = process.argv[2];
const PLAYER_START: Location = {
    r: Number(process.argv[3]),
    c: Number(process.argv[4]),
};
const PLAYER_PRIVKEY: BigInt = BigInt(
    JSON.parse(<string>process.env.ETH_PRIVKEYS)[PLAYER_SYMBOL]
);
const PLAYER = new Player(PLAYER_SYMBOL, PLAYER_PRIVKEY);

/*
 * Misc client parameters.
 */
const BOARD_SIZE: number = parseInt(<string>process.env.BOARD_SIZE, 10);
const UPDATE_MLS: number = 1000;
const MOVE_PROMPT: string = "Next move: ";
const MOVE_KEYS: Record<string, number[]> = {
    w: [-1, 0],
    a: [0, -1],
    s: [1, 0],
    d: [0, 1],
};

/*
 * Boot up interface with 1) Network States contract and 2) the CLI.
 */
const signer = new ethers.Wallet(
    <string>process.env.DEV_PRIV_KEY,
    new ethers.providers.JsonRpcProvider(process.env.RPC_URL)
);
const nStates = new ethers.Contract(
    <string>process.env.CONTRACT_ADDR,
    require(<string>process.env.CONTRACT_ABI).abi,
    signer
);
var rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
});
let cursor = PLAYER_START;

/*
 * Client's local belief on game state stored in Board object.
 */
let b: Board;

/*
 * Whether client should wait for move to be finalized.
 */
let moving: boolean;

/*
 * Using Socket.IO to manage communication with enclave.
 */
const socket: Socket<ServerToClientEvents, ClientToServerEvents> = io(
    `http://localhost:${process.env.SERVER_PORT}`
);

/*
 * Iterates through entire board, asking enclave to reveal all secrets this
 * player is privy to.
 *
 * [TODO] Only ask for tiles that should be out of the fog.
 */
function updatePlayerView() {
    for (let i = 0; i < BOARD_SIZE; i++) {
        for (let j = 0; j < BOARD_SIZE; j++) {
            const l: Location = { r: i, c: j };
            const sig = PLAYER.genSig(Player.hForDecrypt(l));
            socket.emit(
                "decrypt",
                l,
                PLAYER.bjjPub.serialize(),
                Utils.serializeSig(sig)
            );
        }
    }
}

/*
 * Constructs new states induced by army at cursor moving in one of the
 * cardinal directions. Alerts enclave of intended move before sending it
 * to chain. Currently hardcoded to move all but one army unit to the next
 * tile.
 */
async function move(inp: string) {
    // Construct move states
    const nr = cursor.r + MOVE_KEYS[inp][0],
        nc = cursor.c + MOVE_KEYS[inp][1];
    const mTree = await Utils.reconstructMerkleTree(
        Number(process.env.TREE_DEPTH),
        nStates
    );
    const mRoot = mTree.root;

    // Get the current troop/water interval.
    const currentTroopInterval = (
        await nStates.currentTroopInterval()
    ).toNumber();
    const currentWaterInterval = (
        await nStates.currentWaterInterval()
    ).toNumber();

    if (PLAYER.bjjPrivHash === undefined) {
        throw Error("Can't move without a Baby Jubjub private key.");
    }

    const [tFrom, tTo, uFrom, uTo, prf] = await b.constructMove(
        mTree,
        PLAYER.bjjPrivHash,
        cursor,
        { r: nr, c: nc },
        currentTroopInterval,
        currentWaterInterval
    );

    // Alert enclave of intended move
    socket.emit(
        "propose",
        uFrom.toJSON(),
        uTo.toJSON()
    );

    moving = false;

    // This commits a move to to the enclave, whether it is valid or not
    socket.emit(
        "move",
        tFrom.toJSON(),
        tTo.toJSON(),
        uFrom.toJSON(),
        uTo.toJSON()
    );

    // Submit move to chain
    const formattedProof = await Utils.exportCallDataGroth16(prf, [
        mRoot.toString(),
        currentTroopInterval.toString(),
        uFrom.hash(),
        uTo.hash(),
        tFrom.nullifier(),
        tTo.nullifier(),
    ]);
    await nStates.move(
        [
            mRoot.toString(),
            currentTroopInterval.toString(),
            currentWaterInterval.toString(),
            uFrom.hash(),
            uTo.hash(),
            tFrom.nullifier(),
            tTo.nullifier(),
        ],
        formattedProof.a,
        formattedProof.b,
        formattedProof.c
    );

    socket.emit(
        "ping",
        uFrom.toJSON(),
        uTo.toJSON()
    );

    // Update player position
    cursor = { r: nr, c: nc };
}

/*
 * Update local view of game board based on enclave response.
 */
function decryptResponse(t: any) {
    b.setTile(Tile.fromJSON(t));
}

/*
 * Get signature for move proposal. This signature and the queued move will be
 * sent to the chain for approval.
 */
function proposeResponse(sig: any) {
    console.log(sig);
}

async function pingResponse(b: boolean, uFrom: any, uTo: any) {
    if (b) {
        moving = true;
        await updatePlayerView();
        await Utils.sleep(UPDATE_MLS);
    } else {
        socket.emit(
            "ping",
            uFrom,
            uTo
        );
    }
}

/*
 * Refreshes the user's game board view. Done in response to enclave ping that
 * a relevant move was made.
 */
async function updateDisplay() {
    process.stdout.write("\n");
    updatePlayerView();
    await Utils.sleep(UPDATE_MLS);
    b.printView();
    process.stdout.write(MOVE_PROMPT);
}

/*
 * Repeatedly ask user for next move until exit.
 */
async function gameLoop() {
    if (moving) {
        rl.question(MOVE_PROMPT, async (ans) => {
            await move(ans);
            await Utils.sleep(UPDATE_MLS * 2);
            gameLoop();
        });
    } else {
        await Utils.sleep(UPDATE_MLS * 2);
        gameLoop();
    }
}

/*
 * Set up player session with enclave. Spawning if necessary.
 */
socket.on("connect", async () => {
    console.log("Server connection established");

    b = new Board();
    await b.seed(BOARD_SIZE, false, nStates);
    updatePlayerView();
    await Utils.sleep(UPDATE_MLS);
    b.printView();
    moving = true;
    gameLoop();
});

/*
 * Attach event handlers.
 */
socket.on("decryptResponse", decryptResponse);
socket.on("proposeResponse", proposeResponse);
socket.on("pingResponse", pingResponse);
socket.on("updateDisplay", updateDisplay);