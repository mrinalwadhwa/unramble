use std::{net::SocketAddr, str::FromStr};

use freeflow_mock_openai::{MockServer, Scenario};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut address: SocketAddr = "127.0.0.1:8089".parse()?;
    let mut scenario = Scenario::Success;
    let mut arguments = std::env::args().skip(1);
    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--address" => {
                address = arguments
                    .next()
                    .ok_or("--address requires a value")?
                    .parse()?;
            }
            "--scenario" => {
                scenario =
                    Scenario::from_str(&arguments.next().ok_or("--scenario requires a value")?)?;
            }
            "--help" | "-h" => {
                println!(
                    "Usage: freeflow-mock-openai [--address 127.0.0.1:8089] \
                     [--scenario success|realtime-disconnect|realtime-error|batch-fallback|\
                     authentication-failure|rate-limit|delayed|no-speech|malformed|\
                     polish-failure]"
                );
                return Ok(());
            }
            unknown => return Err(format!("unknown argument: {unknown}").into()),
        }
    }

    let server = MockServer::bind(address, scenario).await?;
    println!(
        "{}",
        serde_json::json!({
            "ready": true,
            "apiBaseUrl": server.api_base_url,
            "scenario": scenario
        })
    );
    tokio::signal::ctrl_c().await?;
    Ok(())
}
