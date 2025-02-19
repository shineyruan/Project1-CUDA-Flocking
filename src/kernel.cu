#define GLM_FORCE_CUDA
#include <cuda.h>
#include <stdio.h>

#include <cmath>
#include <glm/glm.hpp>

#include "kernel.h"
#include "utilityCore.hpp"

// LOOK-2.1 potentially useful for doing grid-based neighbor search
#ifndef imax
#define imax(a, b) (((a) > (b)) ? (a) : (b))
#endif

#ifndef imin
#define imin(a, b) (((a) < (b)) ? (a) : (b))
#endif

#define checkCUDAErrorWithLine(msg) checkCUDAError(msg, __LINE__)

/**
 * Check for CUDA errors; print and exit if there was a problem.
 */
void checkCUDAError(const char *msg, int line = -1) {
  cudaError_t err = cudaGetLastError();
  if (cudaSuccess != err) {
    if (line >= 0) {
      fprintf(stderr, "Line %d: ", line);
    }
    fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString(err));
    exit(EXIT_FAILURE);
  }
}

/*****************
 * Configuration *
 *****************/

/*! Block size used for CUDA kernel launch. */
#define blockSize 1024

// LOOK-1.2 Parameters for the boids algorithm.
// These worked well in our reference implementation.
#define rule1Distance 5.0f
#define rule2Distance 3.0f
#define rule3Distance 5.0f

#define rule1Scale 0.01f
#define rule2Scale 0.1f
#define rule3Scale 0.1f

#define maxSpeed 1.0f

/*! Size of the starting area in simulation space. */
#define scene_scale 100.0f

/***********************************************
 * Kernel state (pointers are device pointers) *
 ***********************************************/

int numObjects;
dim3 threadsPerBlock(blockSize);

// LOOK-1.2 - These buffers are here to hold all your boid information.
// These get allocated for you in Boids::initSimulation.
// Consider why you would need two velocity buffers in a simulation where each
// boid cares about its neighbors' velocities.
// These are called ping-pong buffers.
glm::vec3 *dev_pos;
glm::vec3 *dev_vel1;
glm::vec3 *dev_vel2;

// LOOK-2.1 - these are NOT allocated for you. You'll have to set up the thrust
// pointers on your own too.

// For efficient sorting and the uniform grid. These should always be parallel.
int *dev_particleArrayIndices;  // What index in dev_pos and dev_velX represents
                                // this particle?
int *dev_particleGridIndices;   // What grid cell is this particle in?
// needed for use with thrust
thrust::device_ptr<int> dev_thrust_particleArrayIndices;
thrust::device_ptr<int> dev_thrust_particleGridIndices;

int *dev_gridCellStartIndices;  // What part of dev_particleArrayIndices belongs
int *dev_gridCellEndIndices;    // to this cell?

// Part-2.3 - consider what additional buffers you might need to reshuffle
// the position and velocity data to be coherent within cells.
int *dev_posGridIndices;
int *dev_velGridIndices;
thrust::device_ptr<glm::vec3> dev_thrust_pos;
thrust::device_ptr<glm::vec3> dev_thrust_vel;
thrust::device_ptr<int> dev_thrust_posGridIndices;
thrust::device_ptr<int> dev_thrust_velGridIndices;

// LOOK-2.1 - Grid parameters based on simulation parameters.
// These are automatically computed for you in Boids::initSimulation
int gridCellCount;
int gridSideCount;
float gridCellWidth;
float gridInverseCellWidth;
glm::vec3 gridMinimum;

/******************
 * initSimulation *
 ******************/

__host__ __device__ unsigned int hash(unsigned int a) {
  a = (a + 0x7ed55d16) + (a << 12);
  a = (a ^ 0xc761c23c) ^ (a >> 19);
  a = (a + 0x165667b1) + (a << 5);
  a = (a + 0xd3a2646c) ^ (a << 9);
  a = (a + 0xfd7046c5) + (a << 3);
  a = (a ^ 0xb55a4f09) ^ (a >> 16);
  return a;
}

/**
 * LOOK-1.2 - this is a typical helper function for a CUDA kernel.
 * Function for generating a random vec3.
 */
__host__ __device__ glm::vec3 generateRandomVec3(float time, int index) {
  thrust::default_random_engine rng(hash((int)(index * time)));
  thrust::uniform_real_distribution<float> unitDistrib(-1, 1);

  return glm::vec3((float)unitDistrib(rng), (float)unitDistrib(rng),
                   (float)unitDistrib(rng));
}

/**
 * LOOK-1.2 - This is a basic CUDA kernel.
 * CUDA kernel for generating boids with a specified mass randomly around the
 * star.
 */
__global__ void kernGenerateRandomPosArray(int time, int N, glm::vec3 *arr,
                                           float scale) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    glm::vec3 rand = generateRandomVec3(time, index);
    arr[index].x   = scale * rand.x;
    arr[index].y   = scale * rand.y;
    arr[index].z   = scale * rand.z;
  }
}

/**
 * Initialize memory, update some globals
 */
void Boids::initSimulation(int N) {
  numObjects = N;
  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  // LOOK-1.2 - This is basic CUDA memory management and error checking.
  // Don't forget to cudaFree in  Boids::endSimulation.
  cudaMalloc((void **)&dev_pos, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_pos failed!");

  cudaMalloc((void **)&dev_vel1, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel1 failed!");

  cudaMalloc((void **)&dev_vel2, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel2 failed!");

  // LOOK-1.2 - This is a typical CUDA kernel invocation.
  kernGenerateRandomPosArray<<<fullBlocksPerGrid, blockSize>>>(
      1, numObjects, dev_pos, scene_scale);
  checkCUDAErrorWithLine("kernGenerateRandomPosArray failed!");

  // LOOK-2.1 computing grid params
  gridCellWidth =
      2.0f * std::max(std::max(rule1Distance, rule2Distance), rule3Distance);
  int halfSideCount = (int)(scene_scale / gridCellWidth) + 1;
  gridSideCount     = 2 * halfSideCount;

  gridCellCount        = gridSideCount * gridSideCount * gridSideCount;
  gridInverseCellWidth = 1.0f / gridCellWidth;
  float halfGridWidth  = gridCellWidth * halfSideCount;
  gridMinimum.x -= halfGridWidth;
  gridMinimum.y -= halfGridWidth;
  gridMinimum.z -= halfGridWidth;

  std::cout << "gridCellWidth: " << gridCellWidth << std::endl;
  std::cout << "gridInverseCellWidth: " << gridInverseCellWidth << "\n";
  std::cout << "gridSideCount: " << gridSideCount << std::endl;
  std::cout << "gridCellCount: " << gridCellCount << "\n";
  std::cout << "gridMinimum: " << gridMinimum << "\n";

  // Part-2.1 Part-2.3 - Allocate additional buffers here.
  cudaMalloc((void **)&dev_particleArrayIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleArrayIndices failed!");

  cudaMalloc((void **)&dev_particleGridIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleGridIndices failed!");

  cudaMalloc((void **)&dev_gridCellStartIndices, gridCellCount * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_gridCellStartIndices failed!");

  cudaMalloc((void **)&dev_gridCellEndIndices, gridCellCount * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_gridCellEndIndices failed!");

  cudaMalloc((void **)&dev_posGridIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_posGridIndices failed!");

  cudaMalloc((void **)&dev_velGridIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_velGridIndices failed!");

  cudaDeviceSynchronize();
}

/******************
 * copyBoidsToVBO *
 ******************/

/**
 * Copy the boid positions into the VBO so that they can be drawn by OpenGL.
 */
__global__ void kernCopyPositionsToVBO(int N, glm::vec3 *pos, float *vbo,
                                       float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  float c_scale = -1.0f / s_scale;

  if (index < N) {
    vbo[4 * index + 0] = pos[index].x * c_scale;
    vbo[4 * index + 1] = pos[index].y * c_scale;
    vbo[4 * index + 2] = pos[index].z * c_scale;
    vbo[4 * index + 3] = 1.0f;
  }
}

__global__ void kernCopyVelocitiesToVBO(int N, glm::vec3 *vel, float *vbo,
                                        float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  if (index < N) {
    vbo[4 * index + 0] = vel[index].x + 0.3f;
    vbo[4 * index + 1] = vel[index].y + 0.3f;
    vbo[4 * index + 2] = vel[index].z + 0.3f;
    vbo[4 * index + 3] = 1.0f;
  }
}

/**
 * Wrapper for call to the kernCopyboidsToVBO CUDA kernel.
 */
void Boids::copyBoidsToVBO(float *vbodptr_positions,
                           float *vbodptr_velocities) {
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

  kernCopyPositionsToVBO<<<fullBlocksPerGrid, blockSize>>>(
      numObjects, dev_pos, vbodptr_positions, scene_scale);
  kernCopyVelocitiesToVBO<<<fullBlocksPerGrid, blockSize>>>(
      numObjects, dev_vel1, vbodptr_velocities, scene_scale);

  checkCUDAErrorWithLine("copyBoidsToVBO failed!");

  cudaDeviceSynchronize();
}

/******************
 * stepSimulation *
 ******************/

/**
 * LOOK-1.2 You can use this as a helper for kernUpdateVelocityBruteForce.
 * __device__ code can be called from a __global__ context
 * Compute the new velocity on the body with index `iSelf` due to the `N` boids
 * in the `pos` and `vel` arrays.
 */
__device__ glm::vec3 computeVelocityChange(int N, int iSelf,
                                           const glm::vec3 *pos,
                                           const glm::vec3 *vel) {
  const glm::vec3 self_pos = pos[iSelf];
  const glm::vec3 self_vel = vel[iSelf];

  glm::vec3 new_vel = self_vel;

  // Rule 1: boids fly towards their local perceived center of mass, which
  // excludes themselves
  glm::vec3 perceived_center{0.0f, 0.0f, 0.0f};
  int numInfluencingBoids_rule1 = 0;
  for (int i = 0; i < N; ++i) {
    if (i != iSelf && glm::distance(pos[i], self_pos) < rule1Distance) {
      perceived_center += pos[i];
      ++numInfluencingBoids_rule1;
    }
  }
  if (numInfluencingBoids_rule1 > 0) {
    perceived_center /= numInfluencingBoids_rule1;
  }
  new_vel += (perceived_center - self_pos) * rule1Scale;

  // Rule 2: boids try to stay a distance d away from each
  // other
  glm::vec3 center{0.0f, 0.0f, 0.0f};
  for (int i = 0; i < N; ++i) {
    if (i != iSelf && glm::distance(pos[i], self_pos) < rule2Distance) {
      center -= (pos[i] - self_pos);
    }
  }
  new_vel += center * rule2Scale;

  // Rule 3: boids try to match the speed of surrounding boids
  glm::vec3 perceived_vel{0.0f, 0.0f, 0.0f};
  int numInfluencingBoids_rule3 = 0;
  for (int i = 0; i < N; ++i) {
    if (i != iSelf && glm::distance(pos[i], self_pos) < rule3Distance) {
      perceived_vel += vel[i];
      ++numInfluencingBoids_rule3;
    }
  }
  if (numInfluencingBoids_rule3 > 0) {
    perceived_vel /= numInfluencingBoids_rule3;
  }
  new_vel += perceived_vel * rule3Scale;

  return new_vel;
}

/**
 * Implement basic flocking
 * For each of the `N` bodies, update its position based on its current
 * velocity.
 */
__global__ void kernUpdateVelocityBruteForce(int N, const glm::vec3 *pos,
                                             const glm::vec3 *vel1,
                                             glm::vec3 *vel2) {
  int idx = blockDim.x * blockIdx.x + threadIdx.x;

  if (idx < N) {
    glm::vec3 new_vel{0.0f, 0.0f, 0.0f};
    // Compute a new velocity based on pos and vel1
    glm::vec3 new_vel_raw = computeVelocityChange(N, idx, pos, vel1);
    // Clamp the speed
    new_vel = (glm::length(new_vel_raw) <= maxSpeed)
                  ? new_vel_raw
                  : glm::normalize(new_vel_raw) * maxSpeed;
    // Record the new velocity into vel2. Question: why NOT vel1?
    vel2[idx] = new_vel;
  }
}

/**
 * LOOK-1.2 Since this is pretty trivial, we implemented it for you.
 * For each of the `N` bodies, update its position based on its current
 * velocity.
 */
__global__ void kernUpdatePos(int N, float dt, glm::vec3 *pos,
                              const glm::vec3 *vel) {
  // Update position by velocity
  int index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (index >= N) {
    return;
  }
  glm::vec3 thisPos = pos[index];
  thisPos += vel[index] * dt;

  // Wrap the boids around so we don't lose them
  thisPos.x = thisPos.x < -scene_scale ? scene_scale : thisPos.x;
  thisPos.y = thisPos.y < -scene_scale ? scene_scale : thisPos.y;
  thisPos.z = thisPos.z < -scene_scale ? scene_scale : thisPos.z;

  thisPos.x = thisPos.x > scene_scale ? -scene_scale : thisPos.x;
  thisPos.y = thisPos.y > scene_scale ? -scene_scale : thisPos.y;
  thisPos.z = thisPos.z > scene_scale ? -scene_scale : thisPos.z;

  pos[index] = thisPos;
}

// LOOK-2.1 Consider this method of computing a 1D index from a 3D grid index.
// LOOK-2.3 Looking at this method, what would be the most memory efficient
//          order for iterating over neighboring grid cells?
//          for(x)
//            for(y)
//             for(z)? Or some other order?
__device__ int gridIndex3Dto1D(int x, int y, int z, int gridResolution) {
  return x + y * gridResolution + z * gridResolution * gridResolution;
}

__device__ glm::ivec3 gridIndex3D(const glm::vec3 pos, const glm::vec3 gridMin,
                                  const float inverseCellWidth) {
  return static_cast<glm::ivec3>(
      glm::floor((pos - gridMin) * inverseCellWidth));
}

__device__ int gridIndex1D(const glm::vec3 pos, const glm::vec3 gridMin,
                           const float inverseCellWidth,
                           const int gridResolution) {
  glm::ivec3 pos_in_grid = gridIndex3D(pos, gridMin, inverseCellWidth);
  return gridIndex3Dto1D(pos_in_grid.x, pos_in_grid.y, pos_in_grid.z,
                         gridResolution);
}

__global__ void kernComputeIndices(int N, int gridResolution, glm::vec3 gridMin,
                                   float inverseCellWidth, const glm::vec3 *pos,
                                   int *indices, int *gridIndices) {
  // Part 2.1
  int idx = blockIdx.x * blockDim.x + threadIdx.x;

  if (idx < N) {
    // - Label each boid with the index of its grid cell.
    const glm::vec3 boid_pos = pos[idx];
    int boid_gridIdx =
        gridIndex1D(boid_pos, gridMin, inverseCellWidth, gridResolution);
    gridIndices[idx] = boid_gridIdx;
    // - Set up a parallel array of integer indices as pointers to the actual
    //   boid data in pos and vel1/vel2
    indices[idx] = idx;
  }
}

// LOOK-2.1 Consider how this could be useful for indicating that a cell
//          does not enclose any boids
__global__ void kernResetIntBuffer(int N, int *intBuffer, int value) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    intBuffer[index] = value;
  }
}

// Assumes particleGridIndices has been sorted
__global__ void kernIdentifyCellStartEnd(int N, const int *particleGridIndices,
                                         int *gridCellStartIndices,
                                         int *gridCellEndIndices) {
  // Part 2.1
  // Identify the start point of each cell in the gridIndices array.
  // This is basically a parallel unrolling of a loop that goes
  // "this index doesn't match the one before it, must be a new cell!"
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < N) {
    int particleGridIdx      = particleGridIndices[idx];
    int prev_particleGridIdx = -1, next_particleGridIdx = -1;

    if (idx > 0) {
      prev_particleGridIdx = particleGridIndices[idx - 1];
    }
    if (idx < N - 1) {
      next_particleGridIdx = particleGridIndices[idx + 1];
    }

    if (idx == 0 || particleGridIdx != prev_particleGridIdx) {
      gridCellStartIndices[particleGridIdx] = idx;
    }

    if (idx == N - 1 || particleGridIdx != next_particleGridIdx) {
      gridCellEndIndices[particleGridIdx] = idx;
    }
  }
}

__global__ void kernUpdateVelNeighborSearchScattered(
    int N, int gridResolution, glm::vec3 gridMin, float inverseCellWidth,
    float cellWidth, int *gridCellStartIndices, int *gridCellEndIndices,
    int *particleArrayIndices, glm::vec3 *pos, glm::vec3 *vel1,
    glm::vec3 *vel2) {
  // Part-2.1 - Update a boid's velocity using the uniform grid to reduce
  // the number of boids that need to be checked.
  int idx = blockIdx.x * blockDim.x + threadIdx.x;

  if (idx < N) {
    // - Identify the grid cell that this particle is in
    glm::vec3 boid_pos      = pos[idx];
    glm::ivec3 boid_gridPos = gridIndex3D(boid_pos, gridMin, inverseCellWidth);
    int boid_gridIdx        = gridIndex3Dto1D(boid_gridPos.x, boid_gridPos.y,
                                       boid_gridPos.z, gridResolution);

    // - Identify which cells may contain neighbors. This isn't always 8.
    // use grid pos rounding to determine search directions!
    glm::ivec3 boid_gridPosRound = static_cast<glm::ivec3>(
        glm::round((boid_pos - gridMin) * inverseCellWidth));
    glm::ivec3 biasAlongAxes{-1, -1, -1};
    for (int i = 0; i < 3; ++i) {
      if (boid_gridPosRound[i] != boid_gridPos[i]) biasAlongAxes[i] = 1;
    }

    int valid_neighbor_idx_list[8];
    int num_valid_neighbors = 0;
    for (int zStep = 0; zStep <= 1; ++zStep) {
      for (int yStep = 0; yStep <= 1; ++yStep) {
        for (int xStep = 0; xStep <= 1; ++xStep) {
          // z-y-x loop corresponds to LOOK-2.3 question at gridIndex3Dto1D()
          glm::ivec3 grid_pos =
              boid_gridPos + glm::ivec3(xStep * biasAlongAxes[0],
                                        yStep * biasAlongAxes[1],
                                        zStep * biasAlongAxes[2]);
          int grid_idx = gridIndex3Dto1D(grid_pos.x, grid_pos.y, grid_pos.z,
                                         gridResolution);
          if (gridCellStartIndices[grid_idx] >= 0) {
            valid_neighbor_idx_list[num_valid_neighbors++] = grid_idx;
          }
        }
      }
    }

    // - Neighbor Search Velocity Update Main Loop
    glm::vec3 boid_vel = vel1[idx];
    glm::vec3 new_vel  = boid_vel;
    // Rule 1: boids fly towards their local perceived center of mass, which
    // excludes themselves
    glm::vec3 perceived_center{0.0f, 0.0f, 0.0f};
    int numInfluencingNeighbors = 0;
    for (int i = 0; i < num_valid_neighbors; ++i) {
      // - For each cell, read the start/end indices in the boid pointer array.
      int cell_idx            = valid_neighbor_idx_list[i];
      int cell_boid_start_idx = gridCellStartIndices[cell_idx];
      int cell_boid_end_idx   = gridCellEndIndices[cell_idx];
      // - Access each boid in the cell and compute velocity change from
      //   the boids rules, if this boid is within the neighborhood distance.
      for (int j = cell_boid_start_idx; j <= cell_boid_end_idx; ++j) {
        int neighbor_boid_idx = particleArrayIndices[j];
        if (neighbor_boid_idx != idx &&
            glm::distance(pos[neighbor_boid_idx], boid_pos) < rule1Distance) {
          perceived_center += pos[neighbor_boid_idx];
          ++numInfluencingNeighbors;
        }
      }
    }
    if (numInfluencingNeighbors > 0) {
      perceived_center /= numInfluencingNeighbors;
    }
    new_vel += (perceived_center - boid_pos) * rule1Scale;

    // Rule 2: boids try to stay a distance d away from each other
    glm::vec3 center{0.f, 0.f, 0.f};
    for (int i = 0; i < num_valid_neighbors; ++i) {
      int cell_idx            = valid_neighbor_idx_list[i];
      int cell_boid_start_idx = gridCellStartIndices[cell_idx];
      int cell_boid_end_idx   = gridCellEndIndices[cell_idx];
      for (int j = cell_boid_start_idx; j <= cell_boid_end_idx; ++j) {
        int neighbor_boid_idx = particleArrayIndices[j];
        if (neighbor_boid_idx != idx &&
            glm::distance(pos[neighbor_boid_idx], boid_pos) < rule2Distance) {
          center -= (pos[neighbor_boid_idx] - boid_pos);
        }
      }
    }
    new_vel += center * rule2Scale;

    // Rule 3: boids try to match the speed of surrounding boids
    numInfluencingNeighbors = 0;
    glm::vec3 perceived_vel{0.f, 0.f, 0.f};
    for (int i = 0; i < num_valid_neighbors; ++i) {
      int cell_idx            = valid_neighbor_idx_list[i];
      int cell_boid_start_idx = gridCellStartIndices[cell_idx];
      int cell_boid_end_idx   = gridCellEndIndices[cell_idx];
      for (int j = cell_boid_start_idx; j <= cell_boid_end_idx; ++j) {
        int neighbor_boid_idx = particleArrayIndices[j];
        if (neighbor_boid_idx != idx &&
            glm::distance(pos[neighbor_boid_idx], boid_pos) < rule3Distance) {
          perceived_vel += vel1[neighbor_boid_idx];
          ++numInfluencingNeighbors;
        }
      }
    }
    if (numInfluencingNeighbors > 0) {
      perceived_vel /= numInfluencingNeighbors;
    }
    new_vel += perceived_vel * rule3Scale;

    // - Clamp the speed change before putting the new speed in vel2
    if (glm::length(new_vel) > maxSpeed) {
      new_vel = glm::normalize(new_vel) * maxSpeed;
    }

    // - Put the speed change in vel2
    vel2[idx] = new_vel;
  }
}

__global__ void kernUpdateVelNeighborSearchCoherent(
    int N, int gridResolution, glm::vec3 gridMin, float inverseCellWidth,
    float cellWidth, int *gridCellStartIndices, int *gridCellEndIndices,
    glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {
  // Part-2.3 - This should be very similar to
  // kernUpdateVelNeighborSearchScattered, except with one less level of
  // indirection. This should expect gridCellStartIndices and gridCellEndIndices
  // to refer directly to pos and vel1.
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < N) {
    // - Identify the grid cell that this particle is in
    glm::vec3 boid_pos      = pos[idx];
    glm::ivec3 boid_gridPos = gridIndex3D(boid_pos, gridMin, inverseCellWidth);
    int boid_gridIdx        = gridIndex3Dto1D(boid_gridPos.x, boid_gridPos.y,
                                       boid_gridPos.z, gridResolution);

    // - Identify which cells may contain neighbors. This isn't always 8.
    glm::ivec3 boid_gridPosRound = static_cast<glm::ivec3>(
        glm::round((boid_pos - gridMin) * inverseCellWidth));
    glm::ivec3 biasAlongAxes{-1, -1, -1};
    for (int i = 0; i < 3; ++i) {
      if (boid_gridPosRound[i] != boid_gridPos[i]) biasAlongAxes[i] = 1;
    }

    int valid_neighbor_idx_list[8];
    int num_valid_neighbors = 0;
    for (int zStep = 0; zStep <= 1; ++zStep) {
      for (int yStep = 0; yStep <= 1; ++yStep) {
        for (int xStep = 0; xStep <= 1; ++xStep) {
          // z-y-x loop corresponds to LOOK-2.3 question at gridIndex3Dto1D()
          glm::ivec3 grid_pos =
              boid_gridPos + glm::ivec3(xStep * biasAlongAxes[0],
                                        yStep * biasAlongAxes[1],
                                        zStep * biasAlongAxes[2]);
          int grid_idx = gridIndex3Dto1D(grid_pos.x, grid_pos.y, grid_pos.z,
                                         gridResolution);
          if (gridCellStartIndices[grid_idx] >= 0) {
            valid_neighbor_idx_list[num_valid_neighbors++] = grid_idx;
          }
        }
      }
    }

    // - Neighbor Search Velocity Update Main Loop
    glm::vec3 boid_vel = vel1[idx];
    glm::vec3 new_vel  = boid_vel;
    // Rule 1: boids fly towards their local perceived center of mass, which
    // excludes themselves
    glm::vec3 perceived_center{0.0f, 0.0f, 0.0f};
    int numInfluencingNeighbors = 0;
    for (int i = 0; i < num_valid_neighbors; ++i) {
      // - For each cell, read the start/end indices in the boid pointer array.
      int cell_idx            = valid_neighbor_idx_list[i];
      int cell_boid_start_idx = gridCellStartIndices[cell_idx];
      int cell_boid_end_idx   = gridCellEndIndices[cell_idx];
      // - Access each boid in the cell and compute velocity change from
      //   the boids rules, if this boid is within the neighborhood distance.
      for (int j = cell_boid_start_idx; j <= cell_boid_end_idx; ++j) {
        if (j != idx && glm::distance(pos[j], boid_pos) < rule1Distance) {
          perceived_center += pos[j];
          ++numInfluencingNeighbors;
        }
      }
    }
    if (numInfluencingNeighbors > 0) {
      perceived_center /= numInfluencingNeighbors;
    }
    new_vel += (perceived_center - boid_pos) * rule1Scale;

    // Rule 2: boids try to stay a distance d away from each other
    glm::vec3 center{0.f, 0.f, 0.f};
    for (int i = 0; i < num_valid_neighbors; ++i) {
      int cell_idx            = valid_neighbor_idx_list[i];
      int cell_boid_start_idx = gridCellStartIndices[cell_idx];
      int cell_boid_end_idx   = gridCellEndIndices[cell_idx];
      for (int j = cell_boid_start_idx; j <= cell_boid_end_idx; ++j) {
        if (j != idx && glm::distance(pos[j], boid_pos) < rule2Distance) {
          center -= (pos[j] - boid_pos);
        }
      }
    }
    new_vel += center * rule2Scale;

    // Rule 3: boids try to match the speed of surrounding boids
    numInfluencingNeighbors = 0;
    glm::vec3 perceived_vel{0.f, 0.f, 0.f};
    for (int i = 0; i < num_valid_neighbors; ++i) {
      int cell_idx            = valid_neighbor_idx_list[i];
      int cell_boid_start_idx = gridCellStartIndices[cell_idx];
      int cell_boid_end_idx   = gridCellEndIndices[cell_idx];
      for (int j = cell_boid_start_idx; j <= cell_boid_end_idx; ++j) {
        if (j != idx && glm::distance(pos[j], boid_pos) < rule3Distance) {
          perceived_vel += vel1[j];
          ++numInfluencingNeighbors;
        }
      }
    }
    if (numInfluencingNeighbors > 0) {
      perceived_vel /= numInfluencingNeighbors;
    }
    new_vel += perceived_vel * rule3Scale;

    // - Clamp the speed change before putting the new speed in vel2
    if (glm::length(new_vel) > maxSpeed) {
      new_vel = glm::normalize(new_vel) * maxSpeed;
    }

    // - Put the speed change in vel2
    vel2[idx] = new_vel;
  }
}

/**
 * Step the entire N-body simulation by `dt` seconds.
 */
void Boids::stepSimulationNaive(float dt) {
  // use the kernels you wrote to step the simulation forward in time.
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);
  kernUpdateVelocityBruteForce<<<fullBlocksPerGrid, blockSize>>>(
      numObjects, dev_pos, dev_vel1, dev_vel2);
  cudaDeviceSynchronize();

  // ping-pong the velocity buffers
  std::swap(dev_vel1, dev_vel2);

  // update position
  kernUpdatePos<<<fullBlocksPerGrid, blockSize>>>(numObjects, dt, dev_pos,
                                                  dev_vel1);
  cudaDeviceSynchronize();
  checkCUDAErrorWithLine("Naive simulation step failed!");
}

void Boids::stepSimulationScatteredGrid(float dt) {
  // Part-2.1
  // Uniform Grid Neighbor search using Thrust sort.
  dim3 fullBlocksPerGrid_particles((numObjects + blockSize - 1) / blockSize);
  dim3 fullBlocksPerGrid_cells((gridCellCount + blockSize - 1) / blockSize);

  // In Parallel:
  // - label each particle with its array index as well as its grid index.
  //   Use 2x width grids.
  kernResetIntBuffer<<<fullBlocksPerGrid_cells, blockSize>>>(
      gridCellCount, dev_gridCellStartIndices, -1);
  kernResetIntBuffer<<<fullBlocksPerGrid_cells, blockSize>>>(
      gridCellCount, dev_gridCellEndIndices, -1);
  cudaDeviceSynchronize();

  kernComputeIndices<<<fullBlocksPerGrid_particles, blockSize>>>(
      numObjects, gridSideCount, gridMinimum, gridInverseCellWidth, dev_pos,
      dev_particleArrayIndices, dev_particleGridIndices);
  cudaDeviceSynchronize();

  // - Unstable key sort using Thrust. A stable sort isn't necessary, but you
  //   are welcome to do a performance comparison.
  dev_thrust_particleArrayIndices =
      thrust::device_pointer_cast<int>(dev_particleArrayIndices);
  dev_thrust_particleGridIndices =
      thrust::device_pointer_cast<int>(dev_particleGridIndices);
  thrust::sort_by_key(dev_thrust_particleGridIndices,
                      dev_thrust_particleGridIndices + numObjects,
                      dev_thrust_particleArrayIndices);

  // - Naively unroll the loop for finding the start and end indices of each
  //   cell's data pointers in the array of boid indices
  kernIdentifyCellStartEnd<<<fullBlocksPerGrid_particles, blockSize>>>(
      numObjects, dev_particleGridIndices, dev_gridCellStartIndices,
      dev_gridCellEndIndices);
  cudaDeviceSynchronize();

  // - Perform velocity updates using neighbor search
  kernUpdateVelNeighborSearchScattered<<<fullBlocksPerGrid_particles,
                                         blockSize>>>(
      numObjects, gridSideCount, gridMinimum, gridInverseCellWidth,
      gridCellWidth, dev_gridCellStartIndices, dev_gridCellEndIndices,
      dev_particleArrayIndices, dev_pos, dev_vel1, dev_vel2);
  cudaDeviceSynchronize();

  // - Ping-pong buffers as needed
  std::swap(dev_vel1, dev_vel2);

  // - Update positions
  kernUpdatePos<<<fullBlocksPerGrid_particles, blockSize>>>(numObjects, dt,
                                                            dev_pos, dev_vel1);
  cudaDeviceSynchronize();
  checkCUDAErrorWithLine("Naive simulation step failed!");
}

void Boids::stepSimulationCoherentGrid(float dt) {
  // Part-2.3 - start by copying Boids::stepSimulationNaiveGrid
  // Uniform Grid Neighbor search using Thrust sort on cell-coherent data.
  dim3 fullBlocksPerGrid_particles((numObjects + blockSize - 1) / blockSize);
  dim3 fullBlocksPerGrid_cells((gridCellCount + blockSize - 1) / blockSize);

  // In Parallel:
  // - Label each particle with its array index as well as its grid index.
  //   Use 2x width grids
  kernResetIntBuffer<<<fullBlocksPerGrid_cells, blockSize>>>(
      gridCellCount, dev_gridCellStartIndices, -1);
  kernResetIntBuffer<<<fullBlocksPerGrid_cells, blockSize>>>(
      gridCellCount, dev_gridCellEndIndices, -1);
  cudaDeviceSynchronize();

  kernComputeIndices<<<fullBlocksPerGrid_particles, blockSize>>>(
      numObjects, gridSideCount, gridMinimum, gridInverseCellWidth, dev_pos,
      dev_particleArrayIndices, dev_particleGridIndices);
  cudaDeviceSynchronize();

  cudaMemcpy(dev_posGridIndices, dev_particleGridIndices,
             numObjects * sizeof(int), cudaMemcpyDeviceToDevice);
  cudaMemcpy(dev_velGridIndices, dev_particleGridIndices,
             numObjects * sizeof(int), cudaMemcpyDeviceToDevice);
  checkCUDAErrorWithLine(
      "cudaMemcpy dev_posGridIndices/dev_velGridIndices failed!");

  // - Unstable key sort using Thrust. A stable sort isn't necessary, but you
  //   are welcome to do a performance comparison.
  dev_thrust_particleArrayIndices =
      thrust::device_pointer_cast<int>(dev_particleArrayIndices);
  dev_thrust_particleGridIndices =
      thrust::device_pointer_cast<int>(dev_particleGridIndices);
  thrust::sort_by_key(dev_thrust_particleGridIndices,
                      dev_thrust_particleGridIndices + numObjects,
                      dev_thrust_particleArrayIndices);

  // - Naively unroll the loop for finding the start and end indices of each
  //   cell's data pointers in the array of boid indices
  kernIdentifyCellStartEnd<<<fullBlocksPerGrid_particles, blockSize>>>(
      numObjects, dev_particleGridIndices, dev_gridCellStartIndices,
      dev_gridCellEndIndices);
  cudaDeviceSynchronize();

  // - BIG DIFFERENCE: use the rearranged array index buffer to reshuffle all
  //   the particle data in the simulation array.
  //   CONSIDER WHAT ADDITIONAL BUFFERS YOU NEED
  dev_thrust_posGridIndices =
      thrust::device_pointer_cast<int>(dev_posGridIndices);
  dev_thrust_pos = thrust::device_pointer_cast<glm::vec3>(dev_pos);
  thrust::sort_by_key(dev_thrust_posGridIndices,
                      dev_thrust_posGridIndices + numObjects, dev_thrust_pos);
  dev_thrust_velGridIndices =
      thrust::device_pointer_cast<int>(dev_velGridIndices);
  dev_thrust_vel = thrust::device_pointer_cast<glm::vec3>(dev_vel1);
  thrust::sort_by_key(dev_thrust_velGridIndices,
                      dev_thrust_velGridIndices + numObjects, dev_thrust_vel);

  // - Perform velocity updates using neighbor search
  kernUpdateVelNeighborSearchCoherent<<<fullBlocksPerGrid_particles,
                                        blockSize>>>(
      numObjects, gridSideCount, gridMinimum, gridInverseCellWidth,
      gridCellWidth, dev_gridCellStartIndices, dev_gridCellEndIndices, dev_pos,
      dev_vel1, dev_vel2);

  // - Ping-pong buffers as needed. THIS MAY BE DIFFERENT FROM BEFORE.
  std::swap(dev_vel1, dev_vel2);

  // - Update positions
  kernUpdatePos<<<fullBlocksPerGrid_particles, blockSize>>>(numObjects, dt,
                                                            dev_pos, dev_vel1);
}

void Boids::endSimulation() {
  cudaFree(dev_vel1);
  cudaFree(dev_vel2);
  cudaFree(dev_pos);

  // Part-2.1 Part-2.3 - Free any additional buffers here.
  cudaFree(dev_particleArrayIndices);
  cudaFree(dev_particleGridIndices);
  cudaFree(dev_gridCellStartIndices);
  cudaFree(dev_gridCellEndIndices);
  cudaFree(dev_posGridIndices);
  cudaFree(dev_velGridIndices);
}

void Boids::unitTest() {
  // LOOK-1.2 Feel free to write additional tests here.
  std::cout << "---- Begins Thrust Unit Test -----\n";

  // test unstable sort
  int *dev_intKeys;
  int *dev_intValues;
  int N = 10;

  std::unique_ptr<int[]> intKeys{new int[N]};
  std::unique_ptr<int[]> intValues{new int[N]};

  intKeys[0]   = 0;
  intValues[0] = 0;
  intKeys[1]   = 1;
  intValues[1] = 1;
  intKeys[2]   = 0;
  intValues[2] = 2;
  intKeys[3]   = 3;
  intValues[3] = 3;
  intKeys[4]   = 0;
  intValues[4] = 4;
  intKeys[5]   = 2;
  intValues[5] = 5;
  intKeys[6]   = 2;
  intValues[6] = 6;
  intKeys[7]   = 0;
  intValues[7] = 7;
  intKeys[8]   = 5;
  intValues[8] = 8;
  intKeys[9]   = 6;
  intValues[9] = 9;

  cudaMalloc((void **)&dev_intKeys, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intKeys failed!");

  cudaMalloc((void **)&dev_intValues, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intValues failed!");

  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  std::cout << "before unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // How to copy data to the GPU
  cudaMemcpy(dev_intKeys, intKeys.get(), sizeof(int) * N,
             cudaMemcpyHostToDevice);
  cudaMemcpy(dev_intValues, intValues.get(), sizeof(int) * N,
             cudaMemcpyHostToDevice);

  // Wrap device vectors in thrust iterators for use with thrust.
  thrust::device_ptr<int> dev_thrust_keys(dev_intKeys);
  thrust::device_ptr<int> dev_thrust_values(dev_intValues);
  // LOOK-2.1 Example for using thrust::sort_by_key
  thrust::sort_by_key(dev_thrust_keys, dev_thrust_keys + N, dev_thrust_values);

  // How to copy data back to the CPU side from the GPU
  cudaMemcpy(intKeys.get(), dev_intKeys, sizeof(int) * N,
             cudaMemcpyDeviceToHost);
  cudaMemcpy(intValues.get(), dev_intValues, sizeof(int) * N,
             cudaMemcpyDeviceToHost);
  checkCUDAErrorWithLine("memcpy back failed!");

  std::cout << "after unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // cleanup
  cudaFree(dev_intKeys);
  cudaFree(dev_intValues);
  checkCUDAErrorWithLine("cudaFree failed!");
  return;
}
