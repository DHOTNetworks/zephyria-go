use libp2p::{
    gossipsub, identify, mdns, request_response,
    identity::Keypair,
    swarm::NetworkBehaviour,
};
use crate::protocol::{BlockRequest, BlockResponse};

#[derive(NetworkBehaviour)]
pub struct ZephyriaBehaviour {
    pub gossipsub: gossipsub::Behaviour,
    pub identify: identify::Behaviour,
    pub mdns: mdns::tokio::Behaviour,
    pub sync: request_response::cbor::Behaviour<BlockRequest, BlockResponse>,
}

impl ZephyriaBehaviour {
    pub fn new(local_key: Keypair) -> anyhow::Result<Self> {
        // Gossipsub configuration
        let gossipsub_config = gossipsub::ConfigBuilder::default()
            .heartbeat_interval(std::time::Duration::from_secs(1))
            .validation_mode(gossipsub::ValidationMode::Strict)
            .build()
            .map_err(|msg| anyhow::anyhow!("Validation Error: {}", msg))?;

        let message_authenticity = gossipsub::MessageAuthenticity::Signed(local_key.clone());
        let gossipsub = gossipsub::Behaviour::new(message_authenticity, gossipsub_config)
            .map_err(|msg| anyhow::anyhow!("Gossipsub Build Error: {}", msg))?;

        // Identify configuration
        let identify = identify::Behaviour::new(identify::Config::new(
            "/zephyria/1.0.0".into(),
            local_key.public(),
        ));

        // mDNS (for local discovery)
        let mdns = mdns::tokio::Behaviour::new(mdns::Config::default(), local_key.public().to_peer_id())?;

        // Request-Response (Sync)
        let sync = request_response::cbor::Behaviour::new(
            [(
                libp2p::StreamProtocol::new("/zephyria/sync/1.0.0"),
                request_response::ProtocolSupport::Full,
            )],
            request_response::Config::default(),
        );

        Ok(Self {
            gossipsub,
            identify,
            mdns,
            sync,
        })
    }
}
