import { Component, createSignal, Show } from 'solid-js';
import { HouseholdJoinView } from '../pairing/HouseholdJoinView';
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
        <HouseholdJoinView
          title="Bienvenue sur Buntu — Ajouter cette TV à votre salon"
          onJoined={() => props.onComplete()}
          onBack={() => props.onComplete()}
          backLabel="Passer / Explorer Buntu"
          onManualInput={() => setIsManualInput(true)}
        />
      </Show>
    </div>
  );
};
