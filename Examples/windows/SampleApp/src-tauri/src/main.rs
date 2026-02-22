#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod audio_state;
mod commands;
mod demo_encryptor;

use audio_state::AudioState;

fn main() {
    env_logger::init();

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(AudioState::new())
        .invoke_handler(tauri::generate_handler![
            commands::list_capture_devices,
            commands::list_render_devices,
            commands::start_recording,
            commands::pause_recording,
            commands::resume_recording,
            commands::stop_recording,
            commands::get_recordings,
            commands::delete_recording,
            commands::get_diagnostics,
        ])
        .run(tauri::generate_context!())
        .expect("error running sample app");
}
