export const validateChecksum = (data: Buffer, expected: number): boolean => {
  const sum = data.reduce((acc, byte) => acc + byte, 0) & 0xFF;
  return sum === expected;
};
