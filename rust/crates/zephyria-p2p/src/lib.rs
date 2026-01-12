pub mod behaviour;
pub mod haki;
pub mod protocol;
pub use behaviour::ZephyriaBehaviour;
pub use haki::{Haki, Shred};
use libp2p::{
    futures::StreamExt, gossipsub, identity, mdns, swarm::Swarm, Multiaddr, PeerId, SwarmBuilder,
    Transport,
};
use std::time::Duration;
use tokio::sync::mpsc;
// use crate::behaviour::ZephyriaBehaviour; // Removed duplicate

use std::sync::{Arc, RwLock};
use zephyria_core::blockchain::Blockchain;
use zephyria_types::Hash;

pub struct P2PService {
    swarm: Swarm<ZephyriaBehaviour>,
    command_receiver: mpsc::Receiver<Command>,
    blockchain: Arc<RwLock<Blockchain>>,
}

pub enum Command {
    Publish {
        topic: String,
        message: Vec<u8>,
    },
    Listen {
        addr: Multiaddr,
    },
    Dial {
        addr: Multiaddr,
    },
    RequestBlocks {
        peer: PeerId,
        start_hash: Hash,
        limit: u64,
        reverse: bool,
    },
}

impl P2PService {
    pub fn new(
        local_key: identity::Keypair,
        command_receiver: mpsc::Receiver<Command>,
        blockchain: Arc<RwLock<Blockchain>>,
    ) -> anyhow::Result<Self> {
        let local_peer_id = PeerId::from(local_key.public());
        log::info!("Local Peer ID: {}", local_peer_id);

        let swarm = libp2p::SwarmBuilder::with_existing_identity(local_key)
            .with_tokio()
            .with_quic()
            .with_behaviour(|key| {
                ZephyriaBehaviour::new(key.clone()).expect("Failed to create behaviour")
            })?
            .build();

        Ok(Self {
            swarm,
            command_receiver,
            blockchain,
        })
    }

    pub async fn run(mut self) -> anyhow::Result<()> {
        loop {
            tokio::select! {
                event = self.swarm.select_next_some() => {
                    match event {
                        libp2p::swarm::SwarmEvent::NewListenAddr { address, .. } => {
                            log::info!("Listening on {:?}", address);
                        }
                        libp2p::swarm::SwarmEvent::Behaviour(crate::behaviour::ZephyriaBehaviourEvent::Mdns(mdns::Event::Discovered(list))) => {
                            for (peer_id, _multiaddr) in list {
                                self.swarm.behaviour_mut().gossipsub.add_explicit_peer(&peer_id);
                            }
                        }
                        libp2p::swarm::SwarmEvent::Behaviour(crate::behaviour::ZephyriaBehaviourEvent::Sync(event)) => {
                             match event {
                                 libp2p::request_response::Event::Message { peer, message } => {
                                     match message {
                                        libp2p::request_response::Message::Request { request_id: _, request, channel } => {
                                            log::info!("Received Sync Request from {}: {:?}", peer, request);

                                            // Handle Sync Request
                                            let mut blocks = Vec::new();
                                            if let Ok(bc) = self.blockchain.read() {
                                                // Start Block
                                                if let Ok(Some(start_block)) = bc.get_block_by_hash(&request.start_hash) {
                                                    blocks.push(start_block.clone());
                                                    let mut current = start_block;

                                                    for _ in 1..request.limit {
                                                        if request.reverse {
                                                            // Parent traversal
                                                            if let Ok(Some(parent)) = bc.get_block_by_hash(&current.header.parent_hash) {
                                                                blocks.push(parent.clone());
                                                                current = parent;
                                                            } else {
                                                                break;
                                                            }
                                                        } else {
                                                            // Forward traversal by Number
                                                            let next_num = current.header.number + zephyria_types::U256::from(1);
                                                            if let Ok(Some(next)) = bc.get_block_by_number(next_num) {
                                                                blocks.push(next.clone());
                                                                current = next;
                                                            } else {
                                                                break;
                                                            }
                                                        }
                                                    }
                                                }
                                            }

                                            let _ = self.swarm.behaviour_mut().sync.send_response(channel, crate::protocol::BlockResponse { blocks });
                                        }
                                        libp2p::request_response::Message::Response { request_id: _, response } => {
                                            log::info!("Received Sync Response from {}: {} blocks", peer, response.blocks.len());

                                            // Ingest Blocks
                                            if let Ok(mut bc) = self.blockchain.write() {
                                                for block in response.blocks {
                                                    match bc.insert_block(block.clone()) {
                                                        Ok(_) => log::debug!("Synced block {}", block.header.number),
                                                        Err(e) => log::warn!("Failed to insert synced block {}: {}", block.header.number, e),
                                                    }
                                                }
                                            }
                                        }
                                     }
                                 }
                                 _ => {}
                             }
                        }
                        _ => {}
                    }
                }
                command = self.command_receiver.recv() => {
                    match command {
                        Some(Command::Listen { addr }) => {
                            self.swarm.listen_on(addr)?;
                        }
                        Some(Command::Dial { addr }) => {
                            self.swarm.dial(addr)?;
                        }
                        Some(Command::Publish { topic, message }) => {
                             let topic_hash = gossipsub::IdentTopic::new(topic);
                             if let Err(e) = self.swarm.behaviour_mut().gossipsub.publish(topic_hash, message) {
                                 log::error!("Publish error: {:?}", e);
                             }
                        }
                        Some(Command::RequestBlocks { peer, start_hash, limit, reverse }) => {
                             let request = crate::protocol::BlockRequest {
                                 start_hash,
                                 limit,
                                 reverse,
                             };
                             self.swarm.behaviour_mut().sync.send_request(&peer, request);
                        }
                        None => return Ok(()),
                    }
                }
            }
        }
    }
}
