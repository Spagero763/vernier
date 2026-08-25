RPC ?= https://sepolia.unichain.org
ACCOUNT ?= vernier-deployer
SENDER ?= 0xE23c44Dd4a51456786c6681cFE928AAcfa00d619
EXPLORER_API ?= https://unichain-sepolia.blockscout.com/api

BROADCAST = --rpc-url $(RPC) --account $(ACCOUNT) --sender $(SENDER) --broadcast
VERIFY = --verifier blockscout --verifier-url $(EXPLORER_API) --compiler-version 0.8.26 --watch

.PHONY: test cov seed seed-dry clamp deploy state fresh

test:
	forge test

cov:
	forge coverage --no-match-path "test/Fork.t.sol" --report summary

# accrues what elapsed time justifies, then trades both pools. run it often;
# the comparison only builds with real time behind it
seed:
	forge script script/Seed.s.sol:Seed $(BROADCAST)

seed-dry:
	forge script script/Seed.s.sol:Seed --rpc-url $(RPC) --sender $(SENDER)

# reports a jump no real rate produces, to show the bound rejecting it on-chain
clamp:
	forge script script/ClampDemo.s.sol:ClampDemo $(BROADCAST)

deploy:
	forge clean
	forge script script/Deploy.s.sol:Deploy $(BROADCAST)

state:
	@bash script/state.sh

# forge caches chain state per network. after a redeploy it will insist the new
# contracts do not exist until this is cleared
fresh:
	forge clean
	forge cache clean unichain-sepolia
