alter table public.workouts
  add constraint workouts_distance_m_upper_bound check (distance_m <= 1000000),
  add constraint workouts_calories_upper_bound check (calories <= 50000),
  add constraint workouts_steps_upper_bound check (steps <= 500000);
