package main

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

var interfaceNamePattern = regexp.MustCompile(`^[A-Za-z0-9_=+.-]{1,15}$`)

type peerController interface {
	Apply(context.Context, deviceLease) error
	Remove(context.Context, deviceLease) error
	Reset(context.Context) error
}

type wireGuardPeerController struct {
	commandPath string
	interfaceA  string
	interfaceB  string
}

func newWireGuardPeerController(commandPath, interfaceA, interfaceB string) (*wireGuardPeerController, error) {
	if commandPath == "" {
		return nil, errors.New("WireGuard command path is required")
	}
	if !interfaceNamePattern.MatchString(interfaceA) || !interfaceNamePattern.MatchString(interfaceB) || interfaceA == interfaceB {
		return nil, errors.New("WireGuard interface names are invalid")
	}
	return &wireGuardPeerController{commandPath: commandPath, interfaceA: interfaceA, interfaceB: interfaceB}, nil
}

func (controller *wireGuardPeerController) Apply(ctx context.Context, lease deviceLease) error {
	if err := controller.run(ctx, "set", controller.interfaceA, "peer", lease.publicKeyA, "allowed-ips", lease.clientAddressA+"/32", "persistent-keepalive", "25"); err != nil {
		return fmt.Errorf("apply route A peer: %w", err)
	}
	if err := controller.run(ctx, "set", controller.interfaceB, "peer", lease.publicKeyB, "allowed-ips", lease.clientAddressB+"/32", "persistent-keepalive", "25"); err != nil {
		_ = controller.run(ctx, "set", controller.interfaceA, "peer", lease.publicKeyA, "remove")
		return fmt.Errorf("apply route B peer: %w", err)
	}
	return nil
}

func (controller *wireGuardPeerController) Remove(ctx context.Context, lease deviceLease) error {
	var result error
	if lease.publicKeyA != "" {
		if err := controller.run(ctx, "set", controller.interfaceA, "peer", lease.publicKeyA, "remove"); err != nil {
			result = errors.Join(result, fmt.Errorf("remove route A peer: %w", err))
		}
	}
	if lease.publicKeyB != "" {
		if err := controller.run(ctx, "set", controller.interfaceB, "peer", lease.publicKeyB, "remove"); err != nil {
			result = errors.Join(result, fmt.Errorf("remove route B peer: %w", err))
		}
	}
	return result
}

func (controller *wireGuardPeerController) Reset(ctx context.Context) error {
	var result error
	for _, interfaceName := range []string{controller.interfaceA, controller.interfaceB} {
		output, err := controller.output(ctx, "show", interfaceName, "peers")
		if err != nil {
			result = errors.Join(result, fmt.Errorf("list peers on %s: %w", interfaceName, err))
			continue
		}
		for _, publicKey := range strings.Fields(output) {
			if err := controller.run(ctx, "set", interfaceName, "peer", publicKey, "remove"); err != nil {
				result = errors.Join(result, fmt.Errorf("reset peer on %s: %w", interfaceName, err))
			}
		}
	}
	return result
}

func (controller *wireGuardPeerController) run(ctx context.Context, arguments ...string) error {
	_, err := controller.output(ctx, arguments...)
	return err
}

func (controller *wireGuardPeerController) output(ctx context.Context, arguments ...string) (string, error) {
	commandContext, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	command := exec.CommandContext(commandContext, controller.commandPath, arguments...)
	output, err := command.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("wg command failed: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return string(output), nil
}
