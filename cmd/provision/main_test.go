package main

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"strings"
	"testing"

	"github.com/aws/aws-lambda-go/lambdacontext"
)

func TestBeginInvocationTagsEveryLogLineWithTheRequestID(t *testing.T) {
	logs := captureDefaultLogger(t)

	beginInvocation(invocationContext("any-request"), logs.base)
	slog.Info("first")
	slog.Info("second")

	for _, line := range logs.lines(t) {
		if line["request_id"] != "any-request" {
			t.Errorf("line %v carries request_id %v, want any-request", line["msg"], line["request_id"])
		}
	}
}

func TestBeginInvocationReturnsTheRequestID(t *testing.T) {
	logs := captureDefaultLogger(t)

	if got := beginInvocation(invocationContext("any-request"), logs.base); got != "any-request" {
		t.Errorf("beginInvocation() = %q, want any-request", got)
	}
}

// A warm execution environment runs the next invocation in the same process,
// so the second invocation's lines must carry its own ID and nothing else.
func TestBeginInvocationDropsThePreviousInvocationsRequestID(t *testing.T) {
	logs := captureDefaultLogger(t)

	beginInvocation(invocationContext("first-request"), logs.base)
	beginInvocation(invocationContext("second-request"), logs.base)
	slog.Info("second invocation")

	raw := logs.buffer.String()
	if strings.Count(raw, `"request_id"`) != 1 || !strings.Contains(raw, `"request_id":"second-request"`) {
		t.Errorf("log = %s, want exactly one request_id, second-request", raw)
	}
}

func TestBeginInvocationLeavesLinesUntaggedOutsideLambda(t *testing.T) {
	logs := captureDefaultLogger(t)

	beginInvocation(context.Background(), logs.base)
	slog.Info("local run")

	for _, line := range logs.lines(t) {
		if _, ok := line["request_id"]; ok {
			t.Errorf("line %v carries request_id %v, want none", line["msg"], line["request_id"])
		}
	}
}

func invocationContext(requestID string) context.Context {
	return lambdacontext.NewContext(context.Background(), &lambdacontext.LambdaContext{AwsRequestID: requestID})
}

type capturedLogs struct {
	buffer *bytes.Buffer
	base   *slog.Logger
}

// captureDefaultLogger gives a test a base logger writing to a buffer and puts
// the previous default logger back when the test ends. Tests using it must not
// run in parallel, because the default logger is process-wide.
func captureDefaultLogger(t *testing.T) capturedLogs {
	t.Helper()
	previous := slog.Default()
	t.Cleanup(func() { slog.SetDefault(previous) })

	buffer := &bytes.Buffer{}
	return capturedLogs{buffer: buffer, base: slog.New(slog.NewJSONHandler(buffer, nil))}
}

func (c capturedLogs) lines(t *testing.T) []map[string]any {
	t.Helper()
	raw := strings.TrimSpace(c.buffer.String())
	if raw == "" {
		t.Fatal("nothing was logged")
	}
	var lines []map[string]any
	for _, raw := range strings.Split(raw, "\n") {
		var line map[string]any
		if err := json.Unmarshal([]byte(raw), &line); err != nil {
			t.Fatalf("log line %q is not JSON: %v", raw, err)
		}
		lines = append(lines, line)
	}
	return lines
}
