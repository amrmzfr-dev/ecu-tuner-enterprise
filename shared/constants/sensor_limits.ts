// ALWAYS enforce, never bypass
export const SENSOR_LIMITS = {
  RPM:          { min: 0,   max: 8000 },
  BOOST_PSI:    { min: -14, max: 30   },
  AFR:          { min: 10,  max: 20   },
  COOLANT_TEMP: { min: -40, max: 120  },
} as const;
