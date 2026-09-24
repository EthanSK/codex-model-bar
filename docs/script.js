const choices = [...document.querySelectorAll('.model-choice')];
const status = document.querySelector('#preview-status');
const composerModel = document.querySelector('.composer-model');

for (const choice of choices) {
  choice.addEventListener('click', () => {
    for (const button of choices) {
      const selected = button === choice;
      button.classList.toggle('is-current', selected);
      button.setAttribute('aria-pressed', String(selected));
    }
    const name = choice.dataset.model;
    status.textContent = `${name} selected in preview`;
    composerModel.textContent = name;
  });
}
