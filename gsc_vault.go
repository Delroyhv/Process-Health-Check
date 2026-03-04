package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"os"
)

func getSecret() []byte {
	key := os.Getenv("GSC_VAULT_KEY")
	if key == "" {
		seedFile := os.ExpandEnv("$HOME/.gsc_vault_seed")
		if _, err := os.Stat(seedFile); os.IsNotExist(err) {
			newSeed := make([]byte, 32)
			rand.Read(newSeed)
			os.WriteFile(seedFile, []byte(hex.EncodeToString(newSeed)), 0600)
		}
		data, _ := os.ReadFile(seedFile)
		key = string(data)
	}
	hash := sha256.Sum256([]byte(key))
	return hash[:]
}

func encrypt(plaintext string) (string, error) {
	block, err := aes.NewCipher(getSecret())
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return "", err
	}
	ciphertext := gcm.Seal(nonce, nonce, []byte(plaintext), nil)
	return hex.EncodeToString(ciphertext), nil
}

func decrypt(cipherhex string) (string, error) {
	data, err := hex.DecodeString(cipherhex)
	if err != nil {
		return "", err
	}
	block, err := aes.NewCipher(getSecret())
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	nonceSize := gcm.NonceSize()
	if len(data) < nonceSize {
		return "", fmt.Errorf("ciphertext too short")
	}
	nonce, ciphertext := data[:nonceSize], data[nonceSize:]
	plaintext, err := gcm.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return "", err
	}
	return string(plaintext), nil
}

func main() {
	op := flag.String("op", "", "Operation: encrypt or decrypt")
	flag.Parse()

	if flag.NArg() < 1 {
		os.Exit(1)
	}

	val := flag.Arg(0)
	switch *op {
	case "encrypt":
		res, err := encrypt(val)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
		fmt.Println(res)
	case "decrypt":
		res, err := decrypt(val)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
		fmt.Println(res)
	default:
		os.Exit(1)
	}
}
