#!/bin/bash

solana_dir={{ solana_dir }}
ln -sf /usr/share/zoneinfo/Europe/Belfast /etc/localtime
mkdir -p $solana_dir; cd $solana_dir; mkdir logs bin keys
echo "start - $(date +%s) - $(date)" >logs/userdatatimes.log

apt update
apt -y upgrade
apt -y install tuned
tuned-adm profile throughput-performance

# Setup sysctl settings - 1
cat >/etc/sysctl.d/20-solana-udp-buffers.conf <<EOF
# Increase UDP buffer size
net.core.rmem_default = 134217728
net.core.rmem_max = 134217728
net.core.wmem_default = 134217728
net.core.wmem_max = 134217728
EOF
sysctl -p /etc/sysctl.d/20-solana-udp-buffers.conf

# Setup sysctl settings - 2
cat >/etc/sysctl.d/20-solana-mmaps.conf <<EOF
# Increase memory mapped files limit
vm.max_map_count = 500000
vm.swappiness = 0
EOF
sysctl -p /etc/sysctl.d/20-solana-mmaps.conf

# Setup max open files
cat >/etc/security/limits.d/90-solana-nofiles.conf <<EOF
# Increase process file descriptor count limit
* - nofile 500000
EOF
systemctl daemon-reload

# Setup log rotation
cat >/etc/logrotate.d/sol <<EOF
/opt/solana/logs/solana-validator.log {
  rotate 7
  daily
  missingok
  postrotate
    systemctl kill -s USR1 sol.service
  endscript
}
EOF

# Setup sol service
cat >/etc/systemd/system/sol.service <<EOF
[Unit]
Description=Solana Validator
After=network.target
Wants=solana-sys-tuner.service
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=5
User={{ default_user }}
LimitNOFILE=500000
LogRateLimitIntervalSec=0
Environment="PATH=/bin:/usr/bin:/home/{{ default_user }}/.local/share/solana/install/active_release/bin"
ExecStart=/opt/solana/bin/validator.sh

[Install]
WantedBy=multi-user.target
EOF


# Setup solana-sys-tuner service
cat >/etc/systemd/system/solana-sys-tuner.service <<EOF
[Unit]
Description=Solana Sys Tuner
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=5
User={{ default_user }}
LimitNOFILE=500000
LogRateLimitIntervalSec=0
Environment="PATH=/bin:/usr/bin:/home/{{ default_user }}/.local/share/solana/install/active_release/bin"
ExecStart=/opt/solana/bin/solana-sys-tuner.sh

[Install]
WantedBy=multi-user.target
EOF


# validator startup scripts

cat >$solana_dir/bin/validator.sh <<EOF
#!/bin/bash
solana-validator \
  --identity     /opt/solana/keys/validator-keypair.json \
  --vote-account /opt/solana/keys/vote-account-keypair.json \
  --ledger       /opt/solana/validator-ledger \
  --rpc-port     8899 \
  --entrypoint   devnet.solana.com:8001 \
  --limit-ledger-size \
  --log          /opt/solana/logs/solana-validator.log
EOF

cat >$solana_dir/bin/solana-sys-tuner.sh <<EOF
#!/bin/bash
sudo /home/{{ default_user }}/.local/share/solana/install/active_release/bin/solana-sys-tuner \
     --user {{ default_user }} \
     &> /opt/solana/logs/sys-tuner.log
EOF

chmod 770 $solana_dir/bin/*
chown -R {{ default_user }}:{{ default_user }} $solana_dir

# Setup custom scripts - 1
cat >/usr/local/bin/solana-dev-setup <<EOF
#!/bin/bash
curl https://sh.rustup.rs -sSf | sh -s -- -y
source ~/.cargo/env
rustup component add rustfmt
rustup update
git clone --single-branch --branch master https://github.com/solana-labs/solana.git ~/solana && cd ~/solana
cargo build --release &> ~/solana-build.log
# ./run.sh &> ../solana-run.log &
EOF

# Setup custom scripts - 2
cat >/usr/local/bin/solana-bench-dev <<EOF
#!/bin/bash
NDEBUG=1 ~/solana/multinode-demo/bench-tps.sh --entrypoint devnet.solana.com:8001 --faucet devnet.solana.com:9900 --duration 60 --tx_count 50
EOF

chmod 775 /usr/local/bin/solana-*


# user install client
su -l {{ default_user }} -c "
  curl -sSfL https://release.solana.com/stable/install | sh
">logs/install-client.log


# setup validator
su -l {{ default_user }} -c "
  # Setup
  cd /opt/solana
  solanapath=$(echo $PATH | cut -d: -f1)
  for file in $(find $solanapath -maxdepth 1 -type f); do $file -V; done &>> logs/solana-versions.txt
  
  # Environment
  echo Set Environment:
  solana config set --url {{ solana_environment_url }}
  
  # Validator Keygen - unique per solana user
  echo -n '{{ solana_validator_key.private }}' > keys/validator-keypair.json
  echo Get Validator Keypair Public Key:
  solana-keygen pubkey validator-keypair.json > keys/validator-keypair.pubkey
  cat keys/validator-keypair.pubkey
  echo Set Validator Keypair:
  solana config set --keypair keys/validator-keypair.json
  
  # Setup Balance
  echo Airdrop:
  solana airdrop 5
  echo Balance:
  solana balance
  echo Balance Lamports:
  solana balance --lamports
  
  # Vote Account Keygen
  echo Gen Vote Account KeyPair:
  solana-keygen new -o keys/vote-account-keypair.json --no-passphrase
  echo Get Vote Account Keypair Public Key:
  solana-keygen pubkey keys/vote-account-keypair.json > keys/vote-account-keypair.pubkey
  cat keys/vote-account-keypair.pubkey
  echo Set VoteAccount:
  solana create-vote-account keys/vote-account-keypair.json keys/validator-keypair.json
  
  # Start vanity keygen
  echo Starting Vanity KeyGen:
  #solana-keygen grind --starts-with cwhee1:2 &> logs/cloudwheel-vanity.log &
">logs/install-creds.log


# # Setup development env
# apt -y install libssl-dev libudev-dev pkg-config zlib1g-dev llvm clang make && \
# su -l {{ default_user }} -c "
#   /usr/local/bin/solana-dev-setup
# ">logs/dev-setup.log &


# Finally start validator-services
systemctl restart logrotate.service
systemctl enable solana-sys-tuner.service
systemctl restart solana-sys-tuner.service
systemctl enable sol.service
systemctl restart sol.service

echo "https://metrics.solana.com:3000/d/monitor-edge/cluster-telemetry-edge?refresh=60s&orgId=2&var-datasource=Solana%20Metrics%20(read-only)&var-testnet=devnet&var-hostid=$(cat /opt/solana/keys/validator-keypair.pubkey)" > links.txt

echo "end   - $(date +%s) - $(date)" >>logs/userdatatimes.log
