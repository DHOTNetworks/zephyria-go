package main

import (
	"fmt"
	"log"
	"net/http"
)

func main() {
	fs := http.FileServer(http.Dir("./web-test"))
	http.Handle("/", fs)

	port := "8080"
	fmt.Printf("Starting Web Test Server at http://localhost:%s\n", port)
	fmt.Printf("Please open http://localhost:%s in your browser with MetaMask installed.\n", port)

	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatal(err)
	}
}
