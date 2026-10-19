SHELL := /bin/bash

# Local demo key, taken from your environment. Anvil prints ten unlocked test accounts on
# startup — before the demo targets, export the key from its "Private Keys" section,
# account (0) — the 64-hex value, NOT the 40-hex address:
#   export ANVIL_KEY=<64-hex key for account (0)>
# (local demos only, never for real funds). No key is committed to the repo, so the
# submission zip contains no private-key material at all.
ANVIL_KEY ?=
RPC       := http://127.0.0.1:8545

.PHONY: help setup doctor install-foundry test exercise challenge fmt anvil deploy-anvil snapshot restore subscribe redeem nav attest holdings queue clean

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

setup: ## Reinstall lib/ dependencies (rarely needed — lib/ ships with the repo; if lib/ is empty prefer git checkout -- lib)
	@git rev-parse --git-dir >/dev/null 2>&1 || git init -q
	forge install foundry-rs/forge-std --no-commit
	forge install OpenZeppelin/openzeppelin-contracts@v5.0.2 --no-commit
	@echo "done — dependencies ready"

doctor: ## Pre-class self-check: can this machine run the lab? 30 seconds to an answer
	bash scripts/doctor.sh

install-foundry: ## Install Foundry (no foundryup, switches to a mainland mirror automatically)
	bash scripts/install-foundry-cn.sh

test: ## Run the core lab tests (Ex0 checkpoint, should be all green)
	forge test --no-match-path 'test/{challenges,exercises}/*' -vv

exercise: ## Run the student exercises Ex2/Ex3/Ex4/Ex5/Ex6 (red until you finish them)
	forge test --match-path 'test/exercises/*.t.sol' -vv

challenge: ## Run the challenge (fails until the student solves it)
	forge test --match-path 'test/challenges/FalseNav.t.sol' -vv

fmt: ## Format the contracts
	forge fmt

anvil: ## Start a local chain (in a second terminal)
	anvil

deploy-anvil: ## Deploy to the local chain
	PRIVATE_KEY=$(ANVIL_KEY) forge script script/Deploy.s.sol:Deploy \
		--rpc-url $(RPC) --broadcast

snapshot: ## Start a chain and save its state on exit as a snapshot (Ctrl-C saves)
	@echo "run the whole demo once, then Ctrl-C — state goes to demo-state.json"
	anvil --dump-state demo-state.json --port 8545

restore: ## Restore chain state from the snapshot, for when the demo goes sideways
	anvil --load-state demo-state.json --port 8545

## The commands below need USDC=... TBILL=... VAULT=... QUEUE=... CUSTODIAN=... exported first
subscribe: ## make subscribe AMOUNT=1000000000  pay USDC, receive shares at the attested NAV
	cast send $(USDC) "approve(address,uint256)" $(VAULT) $(AMOUNT) --rpc-url $(RPC) --private-key $(ANVIL_KEY)
	cast send $(VAULT) "subscribe(uint256)" $(AMOUNT) --rpc-url $(RPC) --private-key $(ANVIL_KEY)

redeem: ## make redeem AMOUNT=1000000000000000000  hand in shares for a queue ticket
	cast send $(TBILL) "approve(address,uint256)" $(QUEUE) $(AMOUNT) --rpc-url $(RPC) --private-key $(ANVIL_KEY)
	cast send $(QUEUE) "enqueue(uint256)" $(AMOUNT) --rpc-url $(RPC) --private-key $(ANVIL_KEY)

nav: ## Read the attested NAV per share (8 decimals)
	cast call $(VAULT) "navPerShare()(uint256)" --rpc-url $(RPC)

attest: ## make attest NAV=100020000  the reporter posts a new NAV per share
	cast send $(VAULT) "attest(int256)" $(NAV) --rpc-url $(RPC) --private-key $(ANVIL_KEY)

holdings: ## Ask the custodian what it actually holds
	cast call $(CUSTODIAN) "realHoldings()(uint256)" --rpc-url $(RPC)

queue: ## Read what the queue still owes (pendingAssets, 6 decimals)
	cast call $(QUEUE) "pendingAssets()(uint256)" --rpc-url $(RPC)

clean: ## Remove build artifacts
	forge clean
