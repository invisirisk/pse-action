package main

import (
	"bytes"
	"fmt"
	"net/http"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestDemo(t *testing.T) {
	//env := os.Environ()
	data := `{
		"GH": "ghp_DEFzmg7RHrQ2eMe2IF4NxNWQodYpab3VMXXX",
	}`
	r := bytes.NewReader([]byte(data))
	req, _ := http.NewRequest("POST", "https://example.com/post-target", r)
	resp, err := http.DefaultClient.Do(req)
	require.NoError(t, err)
	fmt.Printf("response code %v error %v\n", resp.StatusCode, err)
}
