#pragma once

#include <cuda.h>
#include <device_launch_parameters.h>
#include <stdio.h>
#include <thrust/device_vector.h>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/sort.h>

#include <cmath>
#include <vector>

namespace Boids {
void initSimulation(int N);
void stepSimulationNaive(float dt);
void stepSimulationScatteredGrid(float dt);
void stepSimulationCoherentGrid(float dt);
void copyBoidsToVBO(float *vbodptr_positions, float *vbodptr_velocities);

void endSimulation();
void unitTest();
}  // namespace Boids
