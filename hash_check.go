package main
import("fmt";"github.com/ethereum/go-ethereum/crypto")
func main(){fmt.Println(crypto.Keccak256Hash([]byte("MintCreated(address,uint8,address)")).Hex())}