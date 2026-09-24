const choices = [...document.querySelectorAll('.model-choice')];
const status = document.querySelector('#preview-status');
const composerModel = document.querySelector('.composer-model');
const effortSlider = document.querySelector('#reasoning-preview-slider');
const effortValue = document.querySelector('#reasoning-preview-value');
const effortTicks = document.querySelector('#reasoning-preview-ticks');
const modelEfforts = {
  'Opus 5.5': ['Low', 'Medium', 'High', 'Extra High', 'Max'],
  'Fable 5.1': ['Low', 'Medium', 'High', 'Extra High', 'Max'],
  'GPT-6 Sol': ['Low', 'Medium', 'High', 'Extra High', 'Max', 'Ultra'],
  'GPT-6 Astra': ['Low', 'Medium', 'High', 'Extra High', 'Max', 'Ultra'],
};
let selectedModel = 'Opus 5.5';

function updatePreview() {
  const effort = modelEfforts[selectedModel][Number(effortSlider.value)];
  effortValue.textContent = effort;
  status.textContent = `${selectedModel} · ${effort}`;
}

function updateTicks() {
  effortTicks.replaceChildren(...modelEfforts[selectedModel].map(() => document.createElement('i')));
}

updateTicks();

for (const choice of choices) {
  choice.addEventListener('click', () => {
    for (const button of choices) {
      const selected = button === choice;
      button.classList.toggle('is-current', selected);
      button.setAttribute('aria-pressed', String(selected));
    }
    const name = choice.dataset.model;
    selectedModel = name;
    const levels = modelEfforts[name];
    const previousEffort = effortValue.textContent;
    effortSlider.max = String(levels.length - 1);
    effortSlider.value = String(Math.max(0, levels.indexOf(previousEffort)));
    updateTicks();
    composerModel.textContent = name;
    updatePreview();
  });
}

effortSlider.addEventListener('input', updatePreview);
