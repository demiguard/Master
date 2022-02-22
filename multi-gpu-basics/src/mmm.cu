#ifndef MMM_H
#define MMM_H
#include <iostream> // for debuggin
    
namespace singleGPU {

    template <class ElTp, int T> 
    __global__ void matMultRegTiledKernel(
        ElTp* A,
        ElTp* B,
        ElTp* C, 
        int heightA, 
        int widthB, 
        int widthA
    ) {
        __shared__ ElTp Ash[T][T];

        ElTp Creg[T];

        int const heightB = widthA; 
        int const tidx = threadIdx.x;
        int const tidy = threadIdx.y;
        int const bidx = blockIdx.x;
        int const bidy = blockIdx.y;
        int const jjj = bidx * T * T;
        int const jj  = jjj + tidy * T;
        int const j   = jj + tidx;
        int const ii =  bidy * T;
        //int const bdimx = blockDim.x; // =Tile
        //int const bdimy = blockDim.y; // =Tile

        #pragma unroll
        for(int i = 0; i < T; i++) {
            Creg[i] = 0.0;
        }

        for(int kk = 0; kk < widthA; kk += T){
            //Copy A into temp memory
            if ( tidy + bidy * T < heightA && kk + tidx < widthA ) {
                Ash[tidy][tidx] = A[(tidy + ii)*widthA + kk + tidx]; // Ash[tidy][tidx] = A[tidy + bidy * T][kk + tidx]
            } else {
                Ash[tidy][tidx] = 0.0;
            }
            __syncthreads();
            for(int k = 0; k < T; k++){
                //Copy B into a register
                float b; 
                if ((k + kk) < heightB && j < widthB ) {
                    b = B[(k + kk) * widthB + j];
                } else {
                    b = 0.0;
                }

                #pragma unroll
                for(int i = 0; i < T; i++){
                    Creg[i] += Ash[i][k] * b;
                }
            }
            __syncthreads();


            for(int i = 0; i < T; i++){
                if ((ii + i) < heightA && j < widthB)  {
                    C[(i + ii)*widthB + j] = Creg[i];
                }
            }
        }
    }



    template< class ElTp, int T>
    cudaError_t MMM(
            ElTp* A,
            ElTp* B, 
            ElTp* C, 
            int A_height, 
            int B_width, 
            int B_height
        ) {
            dim3 block(T, T, 1);
            int grid_x = ceil((float)B_width / (T * T));
            int grid_y = ceil((float)A_height / (T)); 
            dim3 grid(grid_x, grid_y, 1);


            matMultRegTiledKernel< ElTp, T ><<<grid, block>>>(A, B, C, A_height, B_width, B_height);
            return cudaGetLastError();
    }

    template<class ElTp, int T>
    __global__ void matMultTrivial(ElTp* A, ElTp* B, ElTp* C, int A_height, int B_width, int B_height){
        const int64_t i = blockIdx.x * blockDim.x + threadIdx.x;
        const int64_t j = blockIdx.y * blockDim.y + threadIdx.y;
        
        if (i < B_width || j < A_height) {
            int accum = 0;
            for(int k = 0; k < B_height; k++){
                accum += A[j*B_height + k] * B[k*B_width + i];
            }
            C[j * A_height + i] = accum;
        }
    }

    template< class ElTp, int T>
    cudaError_t MMM_trivial(
        ElTp* A,
        ElTp* B, 
        ElTp* C, 
        int A_height, 
        int B_width, 
        int B_height
    ) {
        dim3 block(T, T, 1);
        int grid_x = ceil((float)B_width / (T));
        int grid_y = ceil((float)A_height / (T)); 
        dim3 grid(grid_x, grid_y, 1);

        matMultTrivial< ElTp, T ><<<grid, block>>>(A, B, C, A_height, B_width, B_height);


        return cudaPeekAtLastError();
    }


}    

namespace multiGPU {

    template <class ElTp, int T> 
    __global__ void matMultRegTiledKernel(ElTp* A, ElTp* B, ElTp* C, int heightA, int widthB, int widthA, int devID) {
        __shared__ ElTp Ash[T][T];

        ElTp Creg[T];

        int const heightB = widthA; 
        int const tidx = threadIdx.x;
        int const tidy = threadIdx.y;
        int const bidx = blockIdx.x;
        int const bidy = blockIdx.y;
        int const jjj = bidx * T * T;
        int const jj  = jjj + tidy * T;
        int const j   = jj + tidx;
        int const ii =  gridDim.y * T * devID + bidy * T;


        #pragma unroll
        for(int i = 0; i < T; i++) {
            Creg[i] = 0.0;
        }

        for(int kk = 0; kk < widthA; kk += T){
            //Copy A into temp memory
            if ( tidy + ii < heightA && kk + tidx < widthA ) {
                Ash[tidy][tidx] = A[(tidy + ii)*widthA + kk + tidx]; // Ash[tidy][tidx] = A[tidy + bidy * T][kk + tidx]
            } else {
                Ash[tidy][tidx] = 0.0;
            }
            __syncthreads();
            for(int k = 0; k < T; k++){
                //Copy B into a register
                float b; 
                if ((k + kk) < heightB && j < widthB ) {
                    b = B[(k + kk) * widthB + j];
                } else {
                    b = 0.0;
                }

                #pragma unroll
                for(int i = 0; i < T; i++){
                    Creg[i] += Ash[i][k] * b;
                }
            }
        }
        __syncthreads();
        for(int i = 0; i < T; i++){
            if ((ii + i) < heightA && j < widthB)  {
                C[(i + ii) * widthB + j] = Creg[i];
            }
        }
    }


    template< class ElTp, int T>
    cudaError_t MMM(
            ElTp* A,
            ElTp* B, 
            ElTp* C, 
            int A_height, 
            int B_width, 
            int B_height
        ) {

        int DeviceCount;
        cudaGetDeviceCount(&DeviceCount);


        dim3 block(T, T, 1);
        int grid_x_total = ceil((float)B_width / (T * T));
        int grid_y_total = ceil((float)A_height / (T)); 
        
        int grid_x = grid_x_total; // Keep this the same value and divide over the Y's
        int grid_y = (grid_y_total + DeviceCount - 1) / DeviceCount; // Same trick to get matching blocksizes

        dim3 grid(grid_x, grid_y, 1);

        for(int dev_id = 0; dev_id < DeviceCount; dev_id++){
            cudaSetDevice(dev_id);
            matMultRegTiledKernel< ElTp, T ><<<grid, block>>>(A,B,C, A_height, B_width, B_height, dev_id);

        }
        return cudaGetLastError();
    }

    template< class ElTp, int T>
    cudaError_t MMM_emulated(
            ElTp* A,
            ElTp* B, 
            ElTp* C, 
            int A_height, 
            int B_width, 
            int B_height,
            int emulatedDevices
        ) {
        dim3 block(T, T, 1);
        int grid_x_total = ceil((float)B_width / (T * T));
        int grid_y_total = ceil((float)A_height / (T)); 
        int grid_x = grid_x_total; // Keep this the same value and divide over the Y's
        int grid_y = (grid_y_total + emulatedDevices - 1) / emulatedDevices; // Same trick to get matching blocksizes

        dim3 grid(grid_x, grid_y, 1);


        for(int dev_id = 0; dev_id < emulatedDevices; dev_id++){
            matMultRegTiledKernel< ElTp, T ><<<grid, block>>>(A,B,C, A_height, B_width, B_height, dev_id);
        }
        return cudaGetLastError();
    }       

    template<class ElTp, int T>
    __global__ void matMultTrivial(ElTp* A, ElTp* B, ElTp* C, int A_height, int B_width, int B_height, int devID){
        const int64_t i = blockIdx.x * blockDim.x + threadIdx.x;
        const int64_t j = devID * gridDim.y * blockDim.y  + blockIdx.y * blockDim.y + threadIdx.y;
        
        if (i < B_width || j < A_height) {
            int accum = 0;
            for(int k = 0; k < B_height; k++){
                accum += A[j*B_height + k] * B[k*B_width + i];
            }
            C[j * A_height + i] = accum;
        }
    }

    template< class ElTp, int T>
    cudaError_t MMM_trivial_emulated(
            ElTp* A,
            ElTp* B, 
            ElTp* C, 
            int A_height, 
            int B_width, 
            int B_height,
            int emulatedDevices
        ) {
        dim3 block(T, T, 1);
        //std::cout << A_height << ", " << B_width << ", " << B_height << ", " << T <<  "\n";

        int grid_x_total = ceil((float)B_width / (T));
        int grid_y_total = ceil((float)A_height / (T)); 
        
        int grid_x = grid_x_total; // Keep this the same value and divide over the Y's
        int grid_y = (grid_y_total + emulatedDevices - 1) / emulatedDevices; // Same trick to get matching blocksizes

        dim3 grid(grid_x, grid_y, 1);


        for(int dev_id = 0; dev_id < emulatedDevices; dev_id++){
            matMultTrivial< ElTp, T ><<<grid, block>>>(A,B,C, A_height, B_width, B_height, dev_id);
        }
        return cudaGetLastError();
    } 

}

#endif