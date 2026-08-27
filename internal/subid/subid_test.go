package subid

import (
	"strings"
	"testing"
)

func TestParseSubIDs(t *testing.T) {
	tests := []struct {
		name     string
		content  string
		username string
		uid      string
		want     Range
		wantErr  bool
	}{
		{
			name:     "matches by username",
			content:  "ajitem:100000:65536\n",
			username: "ajitem",
			uid:      "1000",
			want:     Range{Start: 100000, Count: 65536},
		},
		{
			name:     "matches by numeric uid",
			content:  "1000:100000:65536\n",
			username: "ajitem",
			uid:      "1000",
			want:     Range{Start: 100000, Count: 65536},
		},
		{
			name:     "skips other users",
			content:  "kush:100000:65536\najitem:165536:65536\n",
			username: "ajitem",
			uid:      "1000",
			want:     Range{Start: 165536, Count: 65536},
		},
		{
			name:     "first match wins",
			content:  "ajitem:100000:65536\najitem:900000:1000\n",
			username: "ajitem",
			uid:      "1000",
			want:     Range{Start: 100000, Count: 65536},
		},
		{
			name:     "ignores comments and blank lines",
			content:  "# delegated ranges\n\najitem:100000:65536\n",
			username: "ajitem",
			uid:      "1000",
			want:     Range{Start: 100000, Count: 65536},
		},
		{
			name:     "no entry for this user",
			content:  "kush:100000:65536\n",
			username: "ajitem",
			uid:      "1000",
			wantErr:  true,
		},
		{
			name:     "empty file",
			content:  "",
			username: "ajitem",
			uid:      "1000",
			wantErr:  true,
		},
		{
			name:     "malformed line is skipped, not fatal",
			content:  "garbage\najitem:100000:65536\n",
			username: "ajitem",
			uid:      "1000",
			want:     Range{Start: 100000, Count: 65536},
		},
		{
			name:     "non-numeric start is an error",
			content:  "ajitem:lots:65536\n",
			username: "ajitem",
			uid:      "1000",
			wantErr:  true,
		},
		{
			name:     "zero-sized range is an error",
			content:  "ajitem:100000:0\n",
			username: "ajitem",
			uid:      "1000",
			wantErr:  true,
		},
		{
			name:     "negative start is rejected",
			content:  "ajitem:-1:65536\n",
			username: "ajitem",
			uid:      "1000",
			wantErr:  true,
		},
		{
			name:     "negative count is rejected",
			content:  "ajitem:100000:-5\n",
			username: "ajitem",
			uid:      "1000",
			wantErr:  true,
		},
		{
			name:     "count that overflows an int is rejected",
			content:  "ajitem:100000:99999999999999999999\n",
			username: "ajitem",
			uid:      "1000",
			wantErr:  true,
		},
		{
			name:     "start that overflows an int is rejected",
			content:  "ajitem:99999999999999999999:65536\n",
			username: "ajitem",
			uid:      "1000",
			wantErr:  true,
		},
		{
			name:     "trailing whitespace around fields is tolerated",
			content:  "  ajitem : 100000 : 65536  \n",
			username: "ajitem",
			uid:      "1000",
			want:     Range{Start: 100000, Count: 65536},
		},
		{
			name:     "line with four fields is skipped, not misread",
			content:  "ajitem:100000:65536:extra\najitem:200000:1024\n",
			username: "ajitem",
			uid:      "1000",
			want:     Range{Start: 200000, Count: 1024},
		},
		{
			name:     "a username that looks like another user's uid does not match",
			content:  "1000:100000:65536\n",
			username: "kush",
			uid:      "1001",
			wantErr:  true,
		},
		{
			name:     "final line without a trailing newline still parses",
			content:  "ajitem:100000:65536",
			username: "ajitem",
			uid:      "1000",
			want:     Range{Start: 100000, Count: 65536},
		},
		{
			name:     "count of exactly one is a valid range",
			content:  "ajitem:100000:1\n",
			username: "ajitem",
			uid:      "1000",
			want:     Range{Start: 100000, Count: 1},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parse(strings.NewReader(tt.content), tt.username, tt.uid)

			if tt.wantErr {
				if err == nil {
					t.Fatalf("want error, got range %+v", got)
				}
				return
			}

			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tt.want {
				t.Errorf("got %+v, want %+v", got, tt.want)
			}
		})
	}
}
