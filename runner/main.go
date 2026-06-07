package main

import (
	"fmt"
	"os"
)

func startupLine() string {
	return "athanor-runner starting"
}

func main() {
	fmt.Println(startupLine())
	os.Exit(0)
}
