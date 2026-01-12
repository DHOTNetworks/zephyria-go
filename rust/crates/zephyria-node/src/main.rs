use anyhow::{Context, Result};
use clap::Parser;
use std::path::PathBuf;
use std::sync::{Arc, RwLock};
use tokio::sync::mpsc;
use zephyria_consensus::ZeliusEngine;
use zephyria_core::blockchain::Blockchain;
use zephyria_p2p::{Command, P2PService};
use zephyria_state::ZephyriaDB;
use zephyria_types::Address;

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    #[arg(long, default_value = "./zephyria_db")]
    data_dir: PathBuf,

    #[arg(long, default_value_t = 30303)]
    port: u16,
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init();
    let args = Args::parse();

    log::info!("Starting Zephyria Node...");
    log::info!("Data Directory: {:?}", args.data_dir);

    // 1. Initialize DB
    std::fs::create_dir_all(&args.data_dir)?;
    let db = Arc::new(ZephyriaDB::new(&args.data_dir)?);

    // 2. Initialize Consensus Engine (Mock validators for now)
    // In a real scenario, validators are loaded from genesis.json or contract state.
    let validators = vec![];
    let local_sk = [0u8; 32]; // TODO: Load from keyfile
    let local_addr = Address::default();
    let engine = Arc::new(ZeliusEngine::new(validators, &local_sk, local_addr));

    // 3. Initialize Blockchain
    let blockchain = Arc::new(RwLock::new(Blockchain::new(db.clone(), engine)?));

    // Log Head
    if let Ok(bc) = blockchain.read() {
        log::info!(
            "Current Head: Number {} Hash {:?}",
            bc.current_head().number,
            bc.current_head().hash()
        );
    }

    // 4. Initialize P2P
    let id_keys = libp2p::identity::Keypair::generate_ed25519();
    let (cmd_sender, cmd_receiver) = mpsc::channel(100);

    let p2p_service = P2PService::new(id_keys, cmd_receiver, blockchain.clone())?;

    let p2p_handle = tokio::spawn(async move {
        if let Err(e) = p2p_service.run().await {
            log::error!("P2P Service Failed: {}", e);
        }
    });

    // 5. Start Listening
    let addr_str = format!("/ip4/0.0.0.0/udp/{}/quic-v1", args.port);
    let addr: libp2p::Multiaddr = addr_str.parse()?;

    cmd_sender.send(Command::Listen { addr }).await?;
    log::info!("Listening on {}", addr_str);

    // Keep running
    p2p_handle.await?;

    Ok(())
}
