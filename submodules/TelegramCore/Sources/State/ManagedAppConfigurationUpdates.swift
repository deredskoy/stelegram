Here’s the conflict resolved to ensure search stays disabled by default. I’ve removed the conflict markers and kept the true fallback:

import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi
import MtProtoKit

func updateAppConfigurationOnce(postbox: Postbox, network: Network) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Int32 in
        return currentAppConfiguration(transaction: transaction).hash
    }
    |> mapToSignal { hash -> Signal<Void, NoError> in
        return network.request(Api.functions.help.getAppConfig(hash: hash))
        |> map { result -> (data: Api.JSONValue, hash: Int32)? in
            switch result {
            case let .appConfig(updatedHash, config):
                return (config, updatedHash)
            case .appConfigNotModified:
                return nil
            }
        }
        |> `catch` { _ -> Signal<(data: Api.JSONValue, hash: Int32)?, NoError> in
            return .single(nil)
        }
        |> mapToSignal { result -> Signal<Void, NoError> in
            guard let result = result else {
                return .complete()
            }
            return postbox.transaction { transaction -> Void in
                if let data = JSON(apiJson: result.data) {
                    updateAppConfiguration(transaction: transaction, { configuration -> AppConfiguration in
                        var configuration = configuration
                        configuration.data = data
                        configuration.hash = result.hash
                        // Default to true so search remains disabled unless explicitly enabled by remote config
                        AppConfiguration.disableSearch = data["ios_disable_search"] as? Bool ?? true
                        return configuration
                    })
                    
                    if let audioTranscriptionCooldownUntilTimestamp = data["transcribe_audio_trial_cooldown_until"] as? Double {
                        _internal_updateAudioTranscriptionTrialState(transaction: transaction, { $0.withUpdatedCooldownUntilTime(Int32(audioTranscriptionCooldownUntilTimestamp)) })
                    } else {
                        _internal_updateAudioTranscriptionTrialState(transaction: transaction, { $0.withUpdatedCooldownUntilTime(nil) })
                    }
                }
            }
        }
    }
}

func managedAppConfigurationUpdates(postbox: Postbox, network: Network) -> Signal<Void, NoError> {
    let poll = Signal<Void, NoError> { subscriber in
        return updateAppConfigurationOnce(postbox: postbox, network: network).start(completed: {
            subscriber.putCompletion()
        })
    }
    return (poll |> then(.complete() |> suspendAwareDelay(1.0 * 60.0 * 60.0, queue: Queue.concurrentDefaultQueue()))) |> restart
}

With this, if ios_disable_search isn’t provided by the server, disableSearch will default to true, keeping search off until explicitly enabled.