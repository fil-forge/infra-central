// Package fund moves USDFC into the payer's FilecoinPay account so that proof
// set creation can lock up against it.
//
// It exists so the payer key never leaves AWS. smelt does the same three
// transactions with `cast` on a developer's machine, reading the key out of
// 1Password; running that against a wallet minted here would pull a funded key
// onto a laptop, which is the one property this deployment is built to avoid.
//
// Three transactions, because USDFC sitting in the payer's wallet is not
// spendable by the storage service. Lockup draws only on funds deposited into
// the FilecoinPay contract, so a freshly faucet-funded wallet still fails with
// InsufficientLockupFunds(..., Available=0):
//
//	approve              let FilecoinPay pull the tokens
//	deposit              credit the payer's FilecoinPay account
//	setOperatorApproval  let warm storage lock those funds up
//
// Nothing here is called by a deployment. Bringing up a stage must never move
// money, so the caller is an operator running `make fund-payer`, and Plan runs on
// its own to show what would happen before anything is signed.
package fund

import (
	"context"
	"crypto/ecdsa"
	"fmt"
	"math/big"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
)

// Only the methods this package calls. A full ABI would be a file to keep in
// step with a contract nobody here deploys.
const (
	erc20ABI = `[
		{"name":"approve","type":"function","stateMutability":"nonpayable",
		 "inputs":[{"name":"spender","type":"address"},{"name":"amount","type":"uint256"}],
		 "outputs":[{"type":"bool"}]},
		{"name":"balanceOf","type":"function","stateMutability":"view",
		 "inputs":[{"name":"account","type":"address"}],
		 "outputs":[{"type":"uint256"}]}
	]`

	filecoinPayABI = `[
		{"name":"deposit","type":"function","stateMutability":"nonpayable",
		 "inputs":[{"name":"token","type":"address"},{"name":"to","type":"address"},{"name":"amount","type":"uint256"}],
		 "outputs":[]},
		{"name":"setOperatorApproval","type":"function","stateMutability":"nonpayable",
		 "inputs":[{"name":"token","type":"address"},{"name":"operator","type":"address"},{"name":"approved","type":"bool"},
		           {"name":"rateAllowance","type":"uint256"},{"name":"lockupAllowance","type":"uint256"},
		           {"name":"maxLockupPeriod","type":"uint256"}],
		 "outputs":[]},
		{"name":"accounts","type":"function","stateMutability":"view",
		 "inputs":[{"name":"token","type":"address"},{"name":"owner","type":"address"}],
		 "outputs":[{"name":"funds","type":"uint256"},{"name":"lockupCurrent","type":"uint256"},
		            {"name":"lockupRate","type":"uint256"},{"name":"lockupLastSettledAt","type":"uint256"}]}
	]`
)

// Config is the chain and contract wiring for one stage.
type Config struct {
	RPCURL      string
	ChainID     int64
	USDFC       string
	FilecoinPay string
	// Operator is the address allowed to lock the deposited funds up, which is
	// the warm storage service contract.
	Operator string
}

// Request is what the operator asked for. Amounts are decimal token strings
// exactly as typed, so the value in the confirmation prompt is the value that
// gets signed.
type Request struct {
	Deposit         string
	RateAllowance   string
	LockupAllowance string
	MaxLockupPeriod uint64
	// ForceDeposit deposits even when the account already holds enough.
	ForceDeposit bool
}

// Plan is what would happen, computed without signing anything.
type Plan struct {
	Payer         string   `json:"payer"`
	ChainID       int64    `json:"chain_id"`
	WalletBalance string   `json:"wallet_balance_usdfc"`
	AccountFunds  string   `json:"account_funds_usdfc"`
	Actions       []string `json:"actions"`
	SkipDeposit   bool     `json:"skip_deposit"`
}

// Result reports what was actually broadcast.
type Result struct {
	Plan
	Transactions []Transaction `json:"transactions"`
	FundsAfter   string        `json:"account_funds_after_usdfc"`
}

// Transaction is one confirmed on-chain action.
type Transaction struct {
	Action string `json:"action"`
	Hash   string `json:"hash"`
	Block  uint64 `json:"block"`
	Status uint64 `json:"status"`
}

type session struct {
	client      *ethclient.Client
	erc20       abi.ABI
	pay         abi.ABI
	usdfc       common.Address
	filecoinPay common.Address
	operator    common.Address
	payer       common.Address
	chainID     *big.Int

	deposit         *big.Int
	rateAllowance   *big.Int
	lockupAllowance *big.Int
	forceDeposit    bool
}

// Prepare reads the chain and reports what Execute would do. It signs nothing
// and needs only the payer's address, so it is safe to run at any time.
func Prepare(ctx context.Context, cfg Config, payerKeyHex string, req Request) (*Plan, error) {
	s, err := newSession(ctx, cfg, payerKeyHex, req)
	if err != nil {
		return nil, err
	}
	defer s.client.Close()

	return s.plan(ctx)
}

// Execute broadcasts the transactions the plan describes and waits for each
// receipt before starting the next, because deposit depends on approve.
func Execute(ctx context.Context, cfg Config, payerKeyHex string, req Request) (*Result, error) {
	s, err := newSession(ctx, cfg, payerKeyHex, req)
	if err != nil {
		return nil, err
	}
	defer s.client.Close()

	plan, err := s.plan(ctx)
	if err != nil {
		return nil, err
	}

	key, err := parseKey(payerKeyHex)
	if err != nil {
		return nil, err
	}
	auth, err := bind.NewKeyedTransactorWithChainID(key, s.chainID)
	if err != nil {
		return nil, fmt.Errorf("build transactor: %w", err)
	}
	auth.Context = ctx

	usdfc := bind.NewBoundContract(s.usdfc, s.erc20, s.client, s.client, s.client)
	pay := bind.NewBoundContract(s.filecoinPay, s.pay, s.client, s.client, s.client)

	result := &Result{Plan: *plan}

	send := func(action string, contract *bind.BoundContract, method string, args ...any) error {
		tx, err := contract.Transact(auth, method, args...)
		if err != nil {
			return fmt.Errorf("%s: %w", action, err)
		}
		receipt, err := bind.WaitMined(ctx, s.client, tx)
		if err != nil {
			return fmt.Errorf("%s: waiting for receipt of %s: %w", action, tx.Hash(), err)
		}
		if receipt.Status != 1 {
			return fmt.Errorf("%s: transaction %s reverted in block %d", action, tx.Hash(), receipt.BlockNumber)
		}
		result.Transactions = append(result.Transactions, Transaction{
			Action: action,
			Hash:   tx.Hash().Hex(),
			Block:  receipt.BlockNumber.Uint64(),
			Status: receipt.Status,
		})
		return nil
	}

	if err := send("approve", usdfc, "approve", s.filecoinPay, s.deposit); err != nil {
		return nil, err
	}

	if !plan.SkipDeposit {
		if err := send("deposit", pay, "deposit", s.usdfc, s.payer, s.deposit); err != nil {
			return nil, err
		}
	}

	if err := send("setOperatorApproval", pay, "setOperatorApproval",
		s.usdfc, s.operator, true,
		s.rateAllowance, s.lockupAllowance, new(big.Int).SetUint64(req.MaxLockupPeriod),
	); err != nil {
		return nil, err
	}

	funds, err := s.accountFunds(ctx)
	if err != nil {
		return nil, err
	}
	result.FundsAfter = FormatUSDFC(funds)

	return result, nil
}

func newSession(ctx context.Context, cfg Config, payerKeyHex string, req Request) (*session, error) {
	for name, value := range map[string]string{
		"RPC URL":             cfg.RPCURL,
		"USDFC address":       cfg.USDFC,
		"FilecoinPay address": cfg.FilecoinPay,
		"operator address":    cfg.Operator,
	} {
		if value == "" {
			return nil, fmt.Errorf("%s is not configured", name)
		}
	}

	deposit, err := ParseUSDFC(req.Deposit)
	if err != nil {
		return nil, fmt.Errorf("deposit: %w", err)
	}
	rate, err := ParseUSDFC(req.RateAllowance)
	if err != nil {
		return nil, fmt.Errorf("rate allowance: %w", err)
	}
	lockup, err := ParseUSDFC(req.LockupAllowance)
	if err != nil {
		return nil, fmt.Errorf("lockup allowance: %w", err)
	}
	if deposit.Sign() == 0 {
		return nil, fmt.Errorf("deposit is zero; nothing to fund")
	}

	key, err := parseKey(payerKeyHex)
	if err != nil {
		return nil, err
	}

	client, err := ethclient.DialContext(ctx, cfg.RPCURL)
	if err != nil {
		return nil, fmt.Errorf("dial %s: %w", cfg.RPCURL, err)
	}

	// Guard against a stale or misconfigured RPC pointing at another network,
	// where these transactions would be signed against the wrong chain.
	chainID, err := client.ChainID(ctx)
	if err != nil {
		client.Close()
		return nil, fmt.Errorf("read chain id: %w", err)
	}
	if chainID.Int64() != cfg.ChainID {
		client.Close()
		return nil, fmt.Errorf("RPC reports chain %d, expected %d: refusing to sign", chainID, cfg.ChainID)
	}

	erc20, err := abi.JSON(strings.NewReader(erc20ABI))
	if err != nil {
		client.Close()
		return nil, fmt.Errorf("parse ERC20 ABI: %w", err)
	}
	pay, err := abi.JSON(strings.NewReader(filecoinPayABI))
	if err != nil {
		client.Close()
		return nil, fmt.Errorf("parse FilecoinPay ABI: %w", err)
	}

	return &session{
		client:          client,
		erc20:           erc20,
		pay:             pay,
		usdfc:           common.HexToAddress(cfg.USDFC),
		filecoinPay:     common.HexToAddress(cfg.FilecoinPay),
		operator:        common.HexToAddress(cfg.Operator),
		payer:           crypto.PubkeyToAddress(key.PublicKey),
		chainID:         chainID,
		deposit:         deposit,
		rateAllowance:   rate,
		lockupAllowance: lockup,
		forceDeposit:    req.ForceDeposit,
	}, nil
}

func (s *session) plan(ctx context.Context) (*Plan, error) {
	balance, err := s.walletBalance(ctx)
	if err != nil {
		return nil, err
	}
	funds, err := s.accountFunds(ctx)
	if err != nil {
		return nil, err
	}

	// The wallet must already hold the tokens; this package moves funds it
	// cannot create.
	if balance.Cmp(s.deposit) < 0 {
		return nil, fmt.Errorf(
			"payer %s holds %s USDFC, less than the %s USDFC deposit; faucet it first at https://forest-explorer.chainsafe.dev/faucet/calibnet_usdfc",
			s.payer, FormatUSDFC(balance), FormatUSDFC(s.deposit))
	}

	skipDeposit := funds.Cmp(s.deposit) >= 0 && !s.forceDeposit

	actions := []string{
		fmt.Sprintf("approve: let FilecoinPay pull %s USDFC from %s", FormatUSDFC(s.deposit), s.payer),
	}
	if skipDeposit {
		actions = append(actions, fmt.Sprintf(
			"deposit: SKIPPED, account already holds %s USDFC", FormatUSDFC(funds)))
	} else {
		actions = append(actions, fmt.Sprintf(
			"deposit: credit %s USDFC to the payer's FilecoinPay account", FormatUSDFC(s.deposit)))
	}
	actions = append(actions, fmt.Sprintf(
		"setOperatorApproval: let %s lock up to %s USDFC at %s USDFC/epoch",
		s.operator, FormatUSDFC(s.lockupAllowance), FormatUSDFC(s.rateAllowance)))

	return &Plan{
		Payer:         s.payer.Hex(),
		ChainID:       s.chainID.Int64(),
		WalletBalance: FormatUSDFC(balance),
		AccountFunds:  FormatUSDFC(funds),
		Actions:       actions,
		SkipDeposit:   skipDeposit,
	}, nil
}

func (s *session) walletBalance(ctx context.Context) (*big.Int, error) {
	contract := bind.NewBoundContract(s.usdfc, s.erc20, s.client, s.client, s.client)

	var out []any
	if err := contract.Call(&bind.CallOpts{Context: ctx}, &out, "balanceOf", s.payer); err != nil {
		return nil, fmt.Errorf("read USDFC balance: %w", err)
	}
	return out[0].(*big.Int), nil
}

// accountFunds reads the first field of the payer's FilecoinPay account, which
// is the balance lockup can actually draw on.
func (s *session) accountFunds(ctx context.Context) (*big.Int, error) {
	contract := bind.NewBoundContract(s.filecoinPay, s.pay, s.client, s.client, s.client)

	var out []any
	if err := contract.Call(&bind.CallOpts{Context: ctx}, &out, "accounts", s.usdfc, s.payer); err != nil {
		return nil, fmt.Errorf("read FilecoinPay account: %w", err)
	}
	return out[0].(*big.Int), nil
}

func parseKey(hexKey string) (*ecdsa.PrivateKey, error) {
	key, err := crypto.HexToECDSA(strings.TrimPrefix(strings.TrimSpace(hexKey), "0x"))
	if err != nil {
		// Deliberately does not wrap: the underlying error can quote the input,
		// and the input is a private key.
		return nil, fmt.Errorf("payer key is not a valid secp256k1 private key")
	}
	return key, nil
}

// Waiting for a receipt on Filecoin means waiting out a ~30 second block, so
// callers get a budget rather than a hang.
const ReceiptBudget = 10 * time.Minute
