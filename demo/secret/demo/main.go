package main

import (
	"fmt"
	"os"

	"github.com/hirochachacha/go-smb2"
	"github.com/spf13/cobra"
)

var rootCmd = &cobra.Command{
	Use: "test",
	Run: func(cmd *cobra.Command, args []string) {
		_ = &smb2.Dialer{}

		// Do Stuff Here
	},
}

func main() {
	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
