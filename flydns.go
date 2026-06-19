// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

// flydns.go is the Fly internal-DNS bridge: a tiny forwarder that
// answers DNS on [::]:53 (UDP+TCP) and relays every query verbatim to
// Fly's internal resolver (--fly-dns-resolver, default [fdaa::3]:53).
//
// It exists so tailnet clients can resolve *.internal names: Tailscale
// split DNS sends the "internal" search domain to this node's Tailscale
// IP, the query lands here, Fly's resolver answers with the 6PN AAAA,
// and the real tailscaled subnet route (configured in tailscale-up.sh,
// not here) carries the connection. DNS messages are opaque to us — we
// just shuttle bytes — so no DNS library is needed.
//
// This is a Fly concern (it talks to Fly's resolver); all *Tailscale*
// configuration lives in the shell/Docker layer, never in Go.
package main

import (
	"flag"
	"io"
	"log"
	"net"
	"strings"
	"time"
)

// dnsListen is where the forwarder binds. [::] covers every interface,
// including the Tailscale one once tailscaled brings it up, so split-DNS
// queries aimed at the node's Tailscale IP are received.
const dnsListen = "[::]:53"

var flyDNSResolver = flag.String("fly-dns-resolver", "",
	`Upstream Fly internal DNS resolver (e.g. "[fdaa::3]:53") to forward *.internal queries to. Served on `+dnsListen+` (UDP+TCP). Empty disables the forwarder.`)

// startFlyDNS launches the DNS forwarder if --fly-dns-resolver is set.
// It is a no-op otherwise. Listener errors are fatal (a misconfigured
// :53 bind should fail loudly at startup, not silently).
func startFlyDNS() {
	resolver := strings.TrimSpace(*flyDNSResolver)
	if resolver == "" {
		return
	}

	pc, err := net.ListenPacket("udp", dnsListen)
	if err != nil {
		log.Fatalf("dns udp listen on %s: %v", dnsListen, err)
	}
	go serveDNSUDP(pc, resolver)

	ln, err := net.Listen("tcp", dnsListen)
	if err != nil {
		log.Fatalf("dns tcp listen on %s: %v", dnsListen, err)
	}
	go serveDNSTCP(ln, resolver)

	log.Printf("serving .internal DNS on %s -> %s", dnsListen, resolver)
}

// serveDNSUDP forwards each received UDP DNS query to resolverAddr and
// writes the answer back to the client.
func serveDNSUDP(pc net.PacketConn, resolverAddr string) {
	defer pc.Close()
	for {
		buf := make([]byte, 4096) // fits EDNS0-advertised sizes
		n, src, err := pc.ReadFrom(buf)
		if err != nil {
			return
		}
		go func(query []byte, src net.Addr) {
			resp, err := forwardDNSUDP(query, resolverAddr)
			if err != nil {
				log.Printf("dns udp forward: %v", err)
				return
			}
			if _, err := pc.WriteTo(resp, src); err != nil {
				log.Printf("dns udp reply: %v", err)
			}
		}(buf[:n], src)
	}
}

func forwardDNSUDP(query []byte, resolverAddr string) ([]byte, error) {
	c, err := net.Dial("udp", resolverAddr)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := c.Write(query); err != nil {
		return nil, err
	}
	resp := make([]byte, 4096)
	n, err := c.Read(resp)
	if err != nil {
		return nil, err
	}
	return resp[:n], nil
}

// serveDNSTCP proxies DNS-over-TCP connections to resolverAddr. The
// 2-byte length framing is preserved transparently because we copy the
// raw stream in both directions.
func serveDNSTCP(ln net.Listener, resolverAddr string) {
	defer ln.Close()
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go func(c net.Conn) {
			defer c.Close()
			up, err := net.Dial("tcp", resolverAddr)
			if err != nil {
				log.Printf("dns tcp forward: %v", err)
				return
			}
			defer up.Close()
			done := make(chan struct{}, 2)
			go func() { io.Copy(up, c); done <- struct{}{} }()
			go func() { io.Copy(c, up); done <- struct{}{} }()
			<-done
		}(c)
	}
}
