package image

import (
	"bytes"
	"compress/gzip"
	"fmt"
	"io"
)

// splitGzip returns the uncompressed payload of each concatenated gzip member.
// bytes.Reader implements io.ByteReader, so compress/gzip does not buffer past
// a member boundary and the next member stays aligned.
func splitGzip(data []byte) ([][]byte, error) {
	br := bytes.NewReader(data)
	var out [][]byte
	for br.Len() > 0 {
		zr, err := gzip.NewReader(br)
		if err != nil {
			return nil, fmt.Errorf("gzip member %d: %w", len(out), err)
		}
		zr.Multistream(false)
		payload, err := io.ReadAll(zr)
		closeErr := zr.Close()
		if err != nil {
			return nil, fmt.Errorf("gzip member %d: %w", len(out), err)
		}
		if closeErr != nil {
			return nil, fmt.Errorf("gzip member %d: %w", len(out), closeErr)
		}
		out = append(out, payload)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("no gzip members")
	}
	return out, nil
}
