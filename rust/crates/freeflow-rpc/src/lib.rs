//! Authenticate and transport the FreeFlow desktop protocol over loopback WebSockets.

mod contract;
mod server;
mod types;

pub use contract::{
    PROTOCOL_VERSION, RPC_METHODS, RPC_NOTIFICATIONS, generate_typescript_contract,
};
pub use server::{RpcHandler, RpcServer, RpcServerHandle};
pub use types::{JsonRpcRequest, JsonRpcResponse, RpcError, RpcNotification};
