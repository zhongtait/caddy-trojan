package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"sync"

	"github.com/caddyserver/certmagic"
	"github.com/imgk/caddy-trojan/app"
	"github.com/imgk/caddy-trojan/pkgs/trojan"
	"github.com/imgk/caddy-trojan/pkgs/x"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: seed_caddy_traffic <caddy-data-dir> <record-count>")
		os.Exit(2)
	}
	count, err := strconv.Atoi(os.Args[2])
	if err != nil || count < 0 || count > 1000000 {
		fmt.Fprintln(os.Stderr, "record-count must be between 0 and 1000000")
		os.Exit(2)
	}
	trafficJSON, err := json.Marshal(app.Traffic{Up: 1, Down: 2})
	if err != nil {
		fmt.Fprintln(os.Stderr, "encoding synthetic traffic record:", err)
		os.Exit(1)
	}
	passwordHash := [trojan.HeaderLen]byte{}
	trojan.GenKey("integration-initial-password", passwordHash[:])
	userKey := x.ByteSliceToString(passwordHash[:])
	storage := &certmagic.FileStorage{Path: os.Args[1]}
	const workerCount = 8
	jobs := make(chan int)
	errors := make([]error, count)
	var workers sync.WaitGroup
	workers.Add(workerCount)
	for worker := 0; worker < workerCount; worker++ {
		go func() {
			defer workers.Done()
			for index := range jobs {
				target := fmt.Sprintf("synthetic-%08d.example:443", index)
				key := "trojan/trojan-target/" + userKey + "/" + hex.EncodeToString([]byte(target))
				errors[index] = storage.Store(context.Background(), key, trafficJSON)
			}
		}()
	}
	for index := 0; index < count; index++ {
		jobs <- index
	}
	close(jobs)
	workers.Wait()
	for _, err := range errors {
		if err != nil {
			fmt.Fprintln(os.Stderr, "storing synthetic traffic record:", err)
			os.Exit(1)
		}
	}
	fmt.Printf("seeded %d synthetic target traffic records\n", count)
}
