export const STEP_MESSAGES = {
  step_1: 'Checking driver availability',
  step_2: 'Preparing runtime dependencies',
  step_3: 'Running driver setup script',
  step_4: 'Detecting platform and Miniconda package',
  step_5: 'Downloading Miniconda installer (.sh only)',
  step_6: 'Extract/install Miniconda (bash … -b -p …)',
  step_7: 'Verifying Python runtime',
  step_8: 'Installation complete',
  completed: 'Camera driver has been updated successfully',
  failed: 'Driver setup failed',
};

export function getStepMessage(stepKey) {
  if (!stepKey) return null;
  return STEP_MESSAGES[String(stepKey).trim()] || `Unknown step: ${stepKey}`;
}
