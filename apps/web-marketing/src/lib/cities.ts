export const cities = ['lagos', 'abuja', 'port-harcourt', 'ibadan', 'kano'] as const;
export type CitySlug = (typeof cities)[number];

export function isCity(value: string): value is CitySlug {
  return (cities as readonly string[]).includes(value);
}
