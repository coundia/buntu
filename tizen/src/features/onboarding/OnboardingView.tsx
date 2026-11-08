import { Component, createSignal, Show } from 'solid-js';
import { PairingView } from '../pairing/PairingView';
import { ManualSourceForm } from './ManualSourceForm';

export interface OnboardingProps {
  onComplete: () => void;
  onAddM3u?: (url: string) => void;
}

export const OnboardingView: Component<OnboardingProps> = (props) => {
  const [isManualInput, setIsManualInput] = createSignal(false);

  return (
    <div style={{ width: '100%', height: '100%' }}>
      <Show when={isManualInput()}>
        <ManualSourceForm
          onAdded={() => props.onComplete()}
          onCancel={() => setIsManualInput(false)}
        />
      </Show>
      <Show when={!isManualInput()}>
        <PairingView
          title="Bienvenue sur Buntu"
          subtitle="Ajoutez votre abonnement depuis votre smartphone en scannant le QR code."
          onSuccess={() => props.onComplete()}
          onBack={() => props.onComplete()}
          onSwitchToManual={() => setIsManualInput(true)}
          onSkip={() => props.onComplete()}
        />
      </Show>
    </div>
  );
};
