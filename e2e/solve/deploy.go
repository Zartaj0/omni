package solve

import (
	"context"

	"github.com/omni-network/omni/e2e/solve/devapp"
	"github.com/omni-network/omni/e2e/solve/symbiotic"
	"github.com/omni-network/omni/lib/contracts/solveinbox"
	"github.com/omni-network/omni/lib/contracts/solveoutbox"
	"github.com/omni-network/omni/lib/errors"
	"github.com/omni-network/omni/lib/ethclient/ethbackend"
	"github.com/omni-network/omni/lib/log"
	"github.com/omni-network/omni/lib/netconf"

	"golang.org/x/sync/errgroup"
)

// DeployContracts deploys solve inbox / outbox contracts, and devnet app (if devnet).
func DeployContracts(ctx context.Context, network netconf.Network, backends ethbackend.Backends) error {
	if !network.ID.IsEphemeral() {
		log.Warn(ctx, "Skipping solve deploy", nil)
		return nil
	}

	log.Info(ctx, "Deploying solve contracts")
	if err := deployBoxes(ctx, network, backends); err != nil {
		return errors.Wrap(err, "deploy boxes")
	}

	// TODO(kevin): idempotent outbox allow calls
	var eg errgroup.Group
	eg.Go(func() error { return devapp.MaybeDeploy(ctx, network.ID, backends) })
	eg.Go(func() error { return devapp.AllowOutboxCalls(ctx, network.ID, backends) })
	eg.Go(func() error { return symbiotic.MaybeFundSolver(ctx, network.ID, backends) })
	eg.Go(func() error { return symbiotic.AllowOutboxCalls(ctx, network.ID, backends) })
	if err := eg.Wait(); err != nil {
		return errors.Wrap(err, "setup targets")
	}

	return nil
}

// DeployContracts deploys solve inbox / outbox contracts.
func deployBoxes(ctx context.Context, network netconf.Network, backends ethbackend.Backends) error {
	var eg errgroup.Group
	for _, chain := range network.EVMChains() {
		eg.Go(func() error {
			backend, err := backends.Backend(chain.ID)
			if err != nil {
				return errors.Wrap(err, "get backend", "chain", chain.Name)
			}

			addr, _, err := solveinbox.DeployIfNeeded(ctx, network.ID, backend)
			if err != nil {
				return errors.Wrap(err, "deploy solve inbox")
			}

			log.Debug(ctx, "SolveInbox deployed", "addr", addr.Hex(), "chain", chain.Name)

			addr, _, err = solveoutbox.DeployIfNeeded(ctx, network.ID, backend)
			if err != nil {
				return errors.Wrap(err, "deploy solve outbox")
			}

			log.Debug(ctx, "SolveOutbox deployed", "addr", addr.Hex(), "chain", chain.Name)

			return nil
		})
	}

	if err := eg.Wait(); err != nil {
		return errors.Wrap(err, "deploy solver boxes")
	}

	return nil
}
