import { PrivKey, PubKey } from "maci-domainobjs";
import {
    Signature,
    formatPrivKeyForBabyJub,
    genPubKey,
    genPrivKey,
    sign,
    verifySignature,
    hash2,
    
} from "maci-crypto";
import { Location } from "./Tile";

export class Player {
    symbol: string;
    bjjPriv?: PrivKey;
    bjjPrivHash?: BigInt;
    bjjPub: PubKey;

    constructor(symb: string, ethPriv?: BigInt, bjjPub_?: PubKey) {
        this.symbol = symb;
        if (ethPriv) {
            this.bjjPriv = new PrivKey(formatPrivKeyForBabyJub(ethPriv));
        } else if (bjjPub_) {
            this.bjjPub = bjjPub_;
        } else {
            this.bjjPriv = new PrivKey(genPrivKey());
        }

        if (this.bjjPriv) {
            this.bjjPub = new PubKey(genPubKey(this.bjjPriv.rawPrivKey));
            this.bjjPrivHash = formatPrivKeyForBabyJub(this.bjjPriv.rawPrivKey);
        }
    }

    static fromPubString(p: string): Player {
        return new Player("", undefined, PubKey.unserialize(p));
    }

    /*
     * Convert Location into field element in Babyjubjub's base field using
     * Poseidon hash. Assumes both row & col are less than the field's modulus.
     * This is used for decrypt requests to dispel FoW.
     */
    static hForDecrypt(l: Location): BigInt {
        return hash2([BigInt(l.r), BigInt(l.c)]);
    }

    /*
     * Signs message (Babyjubjub field element) using EDDSA. Player instance 
     * must already have a derived private key.
     */
    public genSig(h: BigInt): Signature {
        if (this.bjjPriv === undefined) {
            throw Error(
                "Must instantiate Player w/ ETH private key to enable sigs."
            );
        }
        return sign(this.bjjPriv.rawPrivKey, h);
    }

    /*
     * Verifies signature. Player instance must be instantiated with Babyjubjub
     * public key.
     */
    public verifySig(h: BigInt, sig: Signature): boolean {
        if (this.bjjPub === undefined) {
            throw Error(
                "Must instantiate Player w/ ETH public key to enable sigs."
            );
        }
        return verifySignature(h, sig, this.bjjPub.rawPubKey);
    }
}