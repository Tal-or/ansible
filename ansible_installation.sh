#!/usr/bin/env bash

# control node is the node from which you're controlling your other nodes
sudo dnf install ansible -y
ansible-galaxy role install gantsign.ansible-role-golang
