
#include "hip/hip_runtime.h"
#include "gpu_solvers.h"
#define NUM_THREADS 512

// Constants needed:
const double eV_to_J = 1.60217663e-19;          // [C]
const double h_bar = 1.054571817e-34;           // [Js]

// struct is_defect
// {
//     __host__ __device__ bool operator()(const ELEMENT element)
//     {
//         return ((element != DEFECT) && (element != OXYGEN_DEFECT));
//     }
// };

// struct is_not_zero
// {
//     __host__ __device__ bool operator()(const int integer)
//     {
//         return (integer != 0);
//     }
// };

// Collect the indices of the contacts and the vacancies
__global__ void get_is_tunnel(int *is_tunnel, int *tunnel_indices, const ELEMENT *element, 
                              int N_atom, int num_layers_contact, int num_source_inj, int num_ground_ext)
{
    int total_tid = blockIdx.x * blockDim.x + threadIdx.x;
    int total_threads = blockDim.x * gridDim.x;

    for (int idx = total_tid; idx < N_atom; idx += total_threads)
    {
        int yes = 0; 

        // vacancies and contacts have states within the bandgap which are included in the tunneling model
        // include the first layer of the contacts, as the rest are directly connected to it
        // METALS ARE HARDCODED

        if ( element[idx] == VACANCY || 
           ( (element[idx] == Ti_EL || element[idx] == N_EL) &&  (idx > (num_layers_contact - 1)*num_source_inj) && (idx < (N_atom - (num_layers_contact - 1)*num_ground_ext)) )) 
        {
            yes = 1;
        }

        is_tunnel[idx] = yes;
        tunnel_indices[idx] = yes * idx;
    }
}

// Compute the number of nonzeros per row of the matrix including the injection, extraction, and device nodes (excluding the ground). 
// Has dimensions of Nsub by Nsub (by the cpu code)
__global__ void calc_nnz_per_row_T_neighbor( const double *posx_d, const double *posy_d, const double *posz_d,
                                            const ELEMENT *metals, const ELEMENT *element, const int *atom_charge, const double *atom_CB_edge,
                                            const double *lattice, bool pbc, double nn_dist, const double tol,
                                            int num_source_inj, int num_ground_ext, const int num_layers_contact,
                                            int num_metals, int matrix_size, int *nnz_per_row_d){

    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    int Natom = matrix_size - 2; 
    
    // TODO optimize this with a 2D grid instead of 1D
    for(int i = idx; i < Natom - 1; i += blockDim.x * gridDim.x){  // N_atom - 1 to exclude the ground node

        int nnz_row = 0;

        for(int j = 0; j < Natom - 1; j++){ // N_atom - 1 to exclude the ground node

            double dist = site_dist_gpu(posx_d[i], posy_d[i], posz_d[i],
                                        posx_d[j], posy_d[j], posz_d[j],
                                        lattice[0], lattice[1], lattice[2], pbc);
            
            // diagonal terms
            if ( i == j )
            {
                nnz_row++;
            }

            // direct terms 
            else if ( i != j && dist < nn_dist )
            {
                nnz_row++;
            }
        }

        // this can be memset outside the kernel instead
        // source/ground connections
        if ( i < num_source_inj )
        {
            atomicAdd(&nnz_per_row_d[1], 1);
            nnz_row++;
        }
        if ( i > (Natom - num_ground_ext) )
        {
            atomicAdd(&nnz_per_row_d[0], 1);
            nnz_row++;
        }

        nnz_per_row_d[i+2] = nnz_row;

        if ( i == 0 )
        {
            atomicAdd(&nnz_per_row_d[0], 2); // loop connection and diagonal element
            atomicAdd(&nnz_per_row_d[1], 2); // loop connection and diagonal element
        }
    }

}

__global__ void calc_col_idx_T_neighbor(const double *posx_d, const double *posy_d, const double *posz_d,
                                        const ELEMENT *metals, const ELEMENT *element, const int *atom_charge, const double *atom_CB_edge,
                                        const double *lattice, bool pbc, double nn_dist, const double tol,
                                        int num_source_inj, int num_ground_ext, const int num_layers_contact,
                                        int num_metals, int matrix_size, int *nnz_per_row_d, int *row_ptr_d, int *col_indices_d)
{
    // row ptr is already calculated
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    int N_full = matrix_size;
    
    // INDEXED OVER NFULL
    for(int i = idx; i < N_full - 1; i += blockDim.x * gridDim.x){                      // exclude ground node with Nfull - 1

        int nnz_row = 0;

        // loop connection and injection row
        if ( i == 0 )
        {
            for (int j = 0; j < N_full - 1; j++)                                        // exclude ground node with Nfull - 1
            {
                if ( (j < 2) || j > (N_full - num_ground_ext) )
                {
                    col_indices_d[row_ptr_d[i] + nnz_row] = j;
                    nnz_row++;
                }
            }
        }
        // loop connection and extraction row
        if ( i == 1 )
        {
            for (int j = 0; j < num_source_inj + 2; j++)
            {
                col_indices_d[row_ptr_d[i] + nnz_row] = j;
                nnz_row++;
            }
        }

        // inner matrix terms
        if (i >= 2)
        {
            for(int j = 0; j < N_full - 1; j++){                                        // exclude ground node with Nfull - 1

                // add injection term for this row
                if ( (j == 1) && (i < num_source_inj + 2) )
                {
                    col_indices_d[row_ptr_d[i] + nnz_row] = 1;
                    nnz_row++;
                }

                // add extraction term for this row
                if ( (j == 0) && (i > N_full - num_ground_ext) )
                {
                    col_indices_d[row_ptr_d[i] + nnz_row] = 0;
                    nnz_row++;
                }

                if ( j >= 2 ) 
                {
                    double dist = site_dist_gpu(posx_d[i - 2], posy_d[i - 2], posz_d[i - 2],
                                                  posx_d[j - 2], posy_d[j - 2], posz_d[j - 2],
                                                  lattice[0], lattice[1], lattice[2], pbc);
                    
                    // diagonal terms
                    if ( i == j )
                    {
                        col_indices_d[row_ptr_d[i] + nnz_row] = j;
                        nnz_row++;
                    }

                    // direct terms 
                    else if ( i != j && dist < nn_dist )
                    {
                        col_indices_d[row_ptr_d[i] + nnz_row] = j;
                        nnz_row++;
                    }
                }
            }
        }

    }
}


// assemble the data for the T matrix - 1D distribution over rows
__global__ void populate_data_T_neighbor(const double *posx_d, const double *posy_d, const double *posz_d,
                                         const ELEMENT *metals, const ELEMENT *element, const int *atom_charge, const double *atom_CB_edge,
                                         const double *lattice, bool pbc, double nn_dist, const double tol,
                                         const double high_G, const double low_G, const double loop_G, 
                                         const double Vd, const double m_e, const double V0,
                                         int num_source_inj, int num_ground_ext, const int num_layers_contact,
                                         int num_metals, int matrix_size, int *row_ptr_d, int *col_indices_d, double *data_d)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    int N_full = matrix_size;
    int N_atom = matrix_size - 2;
    
    for(int i = idx; i < N_full - 1; i += blockDim.x * gridDim.x){

        for( int j = row_ptr_d[i]; j < row_ptr_d[i+1]; j++ )
        {
            // col_indices_d[j] is the index of j in the matrix. j is the index of the data vector
            // if dealing with a diagonal element, we add the positive value from i = i and j = N_full to include the ground node

            // extraction boundary (row)
            if(i == 0)
            {
                // diagonal element (0, 0) --> add the value from (0, N_full)
                if (col_indices_d[j] == 0)
                {
                    data_d[j] = +high_G;
                }
                // loop connection (0, 1)
                if (col_indices_d[j] == 1)
                {
                    data_d[j] = -loop_G;
                }
                // extraction connections from the device
                if ( col_indices_d[j] > N_full - num_ground_ext )
                {
                    data_d[j] = -high_G;
                } 
            }

            // injection boundary (row)
            if(i == 1)
            {
                // loop connection (1, 0)
                if (col_indices_d[j] == 0)
                {
                    data_d[j] = -loop_G;
                }
                // injection connections to the device
                if ( col_indices_d[j] >= 2 || (col_indices_d[j] > N_full - num_ground_ext) )
                {
                    data_d[j] = -high_G;
                } 
            }

            // inner matrix terms
            if (i >= 2)
            {
                // diagonal elements --> add the value from (i - 2, N_full - 2) if site i - 2 neighbors the ground node
                if (i == col_indices_d[j])
                {
                    double dist_angstrom = site_dist_gpu(posx_d[i - 2], posy_d[i - 2], posz_d[i - 2],
                                                         posx_d[N_atom-1], posy_d[N_atom-1], posz_d[N_atom-1]);                                   
                    bool neighboring_ground = (dist_angstrom < nn_dist);
                    
                    if (neighboring_ground) 
                    {
                        data_d[j] = +high_G;     // assuming all the connections to ground come from the right contact
                    } 
                }

                // extraction boundary (column)
                if ( (col_indices_d[j] == 0) && (i > N_full - num_ground_ext) )
                {
                    data_d[j] = -high_G;
                }

                // injection boundary (column)
                if ( (col_indices_d[j] == 1) && (i < num_source_inj + 2) )
                {
                    data_d[j] = -high_G;
                }

                // off-diagonal inner matrix elements
                if ( (col_indices_d[j] >= 2) && (col_indices_d[j] != i)) 
                {

                    double dist_angstrom = site_dist_gpu(posx_d[i - 2], posy_d[i - 2], posz_d[i - 2],
                                                         posx_d[col_indices_d[j] - 2], posy_d[col_indices_d[j] - 2], posz_d[col_indices_d[j] - 2], 
                                                         lattice[0], lattice[1], lattice[2], pbc);                                       
                        
                    bool neighbor = (dist_angstrom < nn_dist);                                                      

                    // direct terms (neighbor connections)
                    if ( neighbor )
                    {
                        // contacts
                        bool metal1 = is_in_array_gpu<ELEMENT>(metals, element[i - 2], num_metals);
                        bool metal2 = is_in_array_gpu<ELEMENT>(metals, element[col_indices_d[j] - 2], num_metals);

                        // conductive vacancy sites
                        bool cvacancy1 = (element[i - 2] == VACANCY) && (atom_charge[i - 2] == 0);
                        bool cvacancy2 = (element[col_indices_d[j] - 2] == VACANCY) && (atom_charge[col_indices_d[j] - 2] == 0);
                        
                        if ((metal1 && metal2) || (cvacancy1 && cvacancy2))
                        {
                            data_d[j] = -high_G;
                        }
                        else
                        {
                            data_d[j] = -low_G;
                        }
                    }

                }
            }
        }
    }
}


__global__ void populate_data_T_tunnel(double *X, const double *posx, const double *posy, const double *posz,
                                       const ELEMENT *metals, const ELEMENT *element, const int *atom_charge, const double *atom_CB_edge,
                                       const double *lattice, bool pbc, double high_G, double low_G, double loop_G,
                                       double nn_dist, double m_e, double V0, int num_source_inj, int num_ground_ext, const int num_layers_contact,
                                       int N_atom, int num_tunnel_points, const int *tunnel_indices, int num_metals, const double Vd, const double tol)
{

    int tid_total = blockIdx.x * blockDim.x + threadIdx.x;
    int num_threads_total = blockDim.x * gridDim.x;

    int N = num_tunnel_points;

    for (auto idx = tid_total; idx < N * N; idx += num_threads_total)
    {    

        int i = idx / N;
        int j = idx % N;

        double posx_i = posx[tunnel_indices[i]];
        double posx_j = posx[tunnel_indices[j]];

        double posy_i = posy[tunnel_indices[i]];
        double posy_j = posy[tunnel_indices[j]];

        double posz_i = posz[tunnel_indices[i]];
        double posz_j = posz[tunnel_indices[j]];

        double atom_CB_edge_i = atom_CB_edge[tunnel_indices[i]];
        double atom_CB_edge_j = atom_CB_edge[tunnel_indices[j]];

        ELEMENT element_i = element[tunnel_indices[i]];
        ELEMENT element_j = element[tunnel_indices[j]];

        double dist_angstrom = site_dist_gpu(posx_i, posy_i, posz_i, 
                                             posx_j, posy_j, posz_j);

        bool neighbor = (dist_angstrom < nn_dist) && (i != j);

        // tunneling terms occur between not-neighbors
        if (i != j && !neighbor)
        { 
            bool any_vacancy1 = element_i == VACANCY;
            bool any_vacancy2 = element_j == VACANCY;

            // contacts, the last layer has already been excluded when creating the tunnel indices
            bool metal1p = is_in_array_gpu(metals, element_i, num_metals);
            bool metal2p = is_in_array_gpu(metals, element_j, num_metals);

            // types of tunnelling conditions considered
            bool trap_to_trap = (any_vacancy1 && any_vacancy2);
            bool contact_to_trap = (any_vacancy1 && metal2p) || (any_vacancy2 && metal1p);
            bool contact_to_contact = (metal1p && metal2p);

            double local_E_drop = atom_CB_edge_i - atom_CB_edge_j;                // [eV] difference in energy between the two atoms

            // compute the WKB tunneling coefficients for all the tunnelling conditions
            if ((trap_to_trap || contact_to_trap || contact_to_contact)  && (fabs(local_E_drop) > tol))
            {
                
                double prefac = -(sqrt( 2 * m_e ) / h_bar) * (2.0 / 3.0);           // [s/(kg^1/2 * m^2)] coefficient inside the exponential
                double dist = (1e-10)*dist_angstrom;                                // [m] 3D distance between atoms i and j

                if (contact_to_trap)
                {
                    double energy_window = fabs(local_E_drop);                      // [eV] energy window for tunneling from the contacts
                    double dV = 0.01;                                               // [V] energy spacing for numerical integration
                    double dE = eV_to_J * dV;                                       // [eV] energy spacing for numerical integration
                        
                    // integrate over all the occupied energy levels in the contact
                    double T = 0.0;
                    for (double iv = 0; iv < energy_window; iv += dE)
                    {
                        double E1 = eV_to_J * V0 + iv;                                  // [J] Energy distance to CB before tunnelling
                        double E2 = E1 - fabs(local_E_drop);                            // [J] Energy distance to CB after tunnelling

                        if (E2 > 0)                                                     // trapezoidal potential barrier (low field)                 
                        {                                                           
                            T += exp(prefac * (dist / fabs(local_E_drop)) * ( pow(E1, 1.5) - pow(E2, 1.5) ) );
                        }

                        if (E2 < 0)                                                      // triangular potential barrier (high field)                               
                        {
                            T += exp(prefac * (dist / fabs(local_E_drop)) * ( pow(E1, 1.5) )); 
                        } 
                    }
                    X[N * i + j] = -T;      
                } 
                else 
                {
                    double E1 = eV_to_J * V0;                                        // [J] Energy distance to CB before tunnelling
                    double E2 = E1 - fabs(local_E_drop);                             // [J] Energy distance to CB after tunnelling
                          
                    if (E2 > 0)                                                      // trapezoidal potential barrier (low field)
                    {                                                           
                        double T = exp(prefac * (dist / fabs(E1 - E2)) * ( pow(E1, 1.5) - pow(E2, 1.5) ) );
                        X[N * i + j] = -T; 
                    }

                    if (E2 < 0)                                                        // triangular potential barrier (high field)
                    {
                        double T = exp(prefac * (dist / fabs(E1 - E2)) * ( pow(E1, 1.5) ));
                        X[N * i + j] = -T; 
                    }
                }
            }
        }
        
    }
}


__global__ void calc_diagonal_T_gpu( int *col_indices, int *row_ptr, double *data, int matrix_size, double *diagonal)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    for(int i = idx; i < matrix_size - 1; i += blockDim.x * gridDim.x){ // MINUS ONE
        //reduce the elements in the row
        double tmp = 0.0;
        for(int j = row_ptr[i]; j < row_ptr[i+1]; j++){
            if(i != col_indices[j]){
                tmp += data[j];
            }
        }
        // diagonal[i] = -tmp;
        //write the sum of the off-diagonals onto the existing diagonal element
        for(int j = row_ptr[i]; j < row_ptr[i+1]; j++){
            if(i == col_indices[j]){
                data[j] += -tmp;
                diagonal[i] = data[j];
            }
        }
    }
}


__global__ void update_m(double *m, long minidx, int np2)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    // int bid = blockIdx.x;

    if (idx < np2)
    {
        double minm = m[minidx];
        m[idx] += abs(minm);
    }
}


__global__ void copy_pdisp(double *site_power, ELEMENT *element, const ELEMENT *metals, double *pdisp, int *atom_gpu_index, int N_atom,
                           const int num_metals, const double alpha)
{
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int total_threads = blockDim.x * gridDim.x;

    for (int idx = tid; idx < N_atom; idx += total_threads)
    {
        bool metal = is_in_array_gpu(metals, element[atom_gpu_index[idx]], num_metals);
        if (!metal)
            site_power[atom_gpu_index[idx]] = -1 * alpha * pdisp[idx];
    }
}

//extracts the diagonal of the dense submatrix into a global vector
__global__ void extract_diag_tunnel(
    double *tunnel_matrix,
    int *tunnel_indices, 
    int num_tunnel_points,
    double *diagonal
)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    for (int i = idx; i < num_tunnel_points; i += blockDim.x * gridDim.x)
    {
        // +2 since first two indices are the extraction and injection nodes
        diagonal[tunnel_indices[i] + 2] += tunnel_matrix[i * num_tunnel_points + i];
    }
}

__global__ void inverse_vector(double *vec, int N)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    for (int i = idx; i < N; i += blockDim.x * gridDim.x)
    {
        vec[i] = 1.0 / vec[i];
    }
}

template <int NTHREADS>
__global__ void get_imacro_sparse(const double *x_values, const int *x_row_ptr, const int *x_col_ind,
                                  const double *m, double *imacro)
{
    int num_threads = blockDim.x;
    int bid = blockIdx.x;
    int tid = threadIdx.x;
    int total_tid = bid * num_threads + tid;
    int total_threads = num_threads * gridDim.x;

    int row_start = x_row_ptr[1] + 2;
    int row_end = x_row_ptr[2];

    __shared__ double buf[NTHREADS];
    buf[tid] = 0.0;
 
    for (int idx = row_start + total_tid; idx < row_end; idx += total_threads)
    {
        int col_index = x_col_ind[idx];
        if (col_index >= 2) 
        {
            // buf[tid] += x_values[idx] * (m[0] - m[col_index]);               // extracted (= injected when including ground node)
            buf[tid] += x_values[idx] * (m[col_index] - m[1]);                  // injected
        }
    }

    int width = num_threads / 2;
    while (width != 0)
    {
        __syncthreads();
        if (tid < width)
        {
            buf[tid] += buf[tid + width];
        }
        width /= 2;
    }

    if (tid == 0)
    {
        atomicAdd(imacro, buf[0]);
    }
}


// used to be called 'set_diag'
__global__ void write_to_diag_T(double *A, double *diag, int N)
{
    int didx = blockIdx.x * blockDim.x + threadIdx.x;
    if (didx < N)
    {
        A[didx * N + didx] -= diag[didx];
    }
}

// new version with split matrix for neighbor/tunnel connections
void update_power_gpu_split(hipblasHandle_t handle, hipsolverHandle_t handle_cusolver, GPUBuffers &gpubuf, 
                            const int num_source_inj, const int num_ground_ext, const int num_layers_contact,
                            const double Vd, const int pbc, const double high_G, const double low_G, const double loop_G, const double G0, const double tol,
                            const double nn_dist, const double m_e, const double V0, int num_metals, double *imacro,
                            const bool solve_heating_local, const bool solve_heating_global, const double alpha_disp)
{
    auto t0 = std::chrono::steady_clock::now();

    // ***************************************************************************************
    // 1. Update the atoms array from the sites array using copy_if with is_defect as a filter
    int *gpu_index;
    int *atom_gpu_index;
    gpuErrchk( hipMalloc((void **)&gpu_index, gpubuf.N_ * sizeof(int)) );                                           // indices of the site array
    gpuErrchk( hipMalloc((void **)&atom_gpu_index, gpubuf.N_ * sizeof(int)) );                                      // indices of the atom array

    thrust::device_ptr<int> gpu_index_ptr = thrust::device_pointer_cast(gpu_index);
    thrust::sequence(gpu_index_ptr, gpu_index_ptr + gpubuf.N_, 0);

    // do these in parallel with a kernel! - check that the positions dont change
    // check if there's some buffer which can be allocated and reused for all of these
    double *last_atom = thrust::copy_if(thrust::device, gpubuf.site_x, gpubuf.site_x + gpubuf.N_, gpubuf.site_element, gpubuf.atom_x, is_defect());
    int N_atom = last_atom - gpubuf.atom_x;
    thrust::copy_if(thrust::device, gpubuf.site_y, gpubuf.site_y + gpubuf.N_, gpubuf.site_element, gpubuf.atom_y, is_defect());
    thrust::copy_if(thrust::device, gpubuf.site_z, gpubuf.site_z + gpubuf.N_, gpubuf.site_element, gpubuf.atom_z, is_defect());
    thrust::copy_if(thrust::device, gpubuf.site_charge, gpubuf.site_charge + gpubuf.N_, gpubuf.site_element, gpubuf.atom_charge, is_defect());
    thrust::copy_if(thrust::device, gpubuf.site_element, gpubuf.site_element + gpubuf.N_, gpubuf.site_element, gpubuf.atom_element, is_defect());
    thrust::copy_if(thrust::device, gpubuf.site_CB_edge, gpubuf.site_CB_edge + gpubuf.N_, gpubuf.site_element, gpubuf.atom_CB_edge, is_defect());
    thrust::copy_if(thrust::device, gpu_index, gpu_index + gpubuf.N_, gpubuf.site_element, atom_gpu_index, is_defect());

    auto t1 = std::chrono::steady_clock::now();
    std::chrono::duration<double> dt = t1 - t0;
    std::cout << "time to update atom arrays: " << dt.count() << "\n";

    // ***************************************************************************************
    // 2. Collect the indices of the contacts and the vacancies    
    int num_threads = 1024;
    int num_blocks = (N_atom - 1) / num_threads + 1;
    // int num_blocks = blocks_per_row * N_atom;

    // indices of the tunneling connections (contacts and vacancies) in the Natom array
    int *is_tunnel; // [0, 1, 0, 0, 1...] where 1 indicates a tunnel connection
    int *is_tunnel_indices; // [0, 1, 0, 0, 4...] storing the indices of the tunnel connections
    gpuErrchk( hipMalloc((void **)&is_tunnel, N_atom * sizeof(int)) );    
    gpuErrchk( hipMalloc((void **)&is_tunnel_indices, N_atom * sizeof(int)) );                                         
    hipLaunchKernelGGL(get_is_tunnel, num_blocks, num_threads, 0, 0, is_tunnel, is_tunnel_indices, gpubuf.atom_element, N_atom, num_layers_contact, num_source_inj, num_ground_ext);
    gpuErrchk( hipPeekAtLastError() );
    hipDeviceSynchronize();
    // check if global counter could be faster

    // boolean array of whether this location in Natoms is a tunnel connection or not
    int num_tunnel_points = thrust::reduce(thrust::device, is_tunnel, is_tunnel + N_atom, 0); // sum([0, 1, 0, 0, 1...])
    gpuErrchk( hipPeekAtLastError() );
    std::cout << "size of tunneling submatrix: " << num_tunnel_points << "\n";

    int *tunnel_indices; // [1, 4...]
    gpuErrchk( hipMalloc((void **)&tunnel_indices, num_tunnel_points * sizeof(int)) ); 
    thrust::copy_if(thrust::device, is_tunnel_indices, is_tunnel_indices + gpubuf.N_, tunnel_indices, is_not_zero());

    auto tx1 = std::chrono::steady_clock::now();
    std::chrono::duration<double> dtx1 = tx1 - t1;
    std::cout << "time to create tunneling indices (included): " << dtx1.count() << "\n";
    
    // // debug
    // int *check_tunnel_inds = new int[num_tunnel_points];
    // gpuErrchk( hipMemcpy(check_tunnel_inds, tunnel_indices, num_tunnel_points * sizeof(int), hipMemcpyDeviceToHost) );
    // for (int i = 0; i < num_tunnel_points; i++)
    // {
    //     std::cout << check_tunnel_inds[i] << " ";
    // }
    // exit(1);
    // // end debug

    // copy back and print tunnel_indices  to file:
    // int *tunnel_indices_h = new int[num_tunnel_points];
    // gpuErrchk( hipMemcpy(tunnel_indices_h, tunnel_indices, num_tunnel_points * sizeof(int), hipMemcpyDeviceToHost) );
    // std::ofstream tunnel_indices_file("tunnel_indices.txt");
    // for (int i = 0; i < num_tunnel_points; i++)
    // {
    //     tunnel_indices_file << tunnel_indices_h[i] << "\n";
    // }
    // tunnel_indices_file.close();
    // exit(1);

    // **************************************************************************
    // 3. Assemble the sparsity pattern of the sparse neighbor matrix
    int Nfull = N_atom + 2;
    int matrix_size = Nfull; 
    int submatrix_size = Nfull - 1;

    // get the number of nonzeros per row
    int *neighbor_nnz_per_row_d;
    gpuErrchk( hipMalloc((void **)&neighbor_nnz_per_row_d, matrix_size * sizeof(int)) );
    gpuErrchk( hipMemset(neighbor_nnz_per_row_d, 0, matrix_size * sizeof(int)) );

    num_threads = 512;
    num_blocks = (matrix_size + num_threads - 1) / num_threads;
    hipLaunchKernelGGL(calc_nnz_per_row_T_neighbor, num_blocks, num_threads, 0, 0, gpubuf.atom_x, gpubuf.atom_y, gpubuf.atom_z,
                                                             gpubuf.metal_types, gpubuf.atom_element, gpubuf.atom_charge, gpubuf.atom_CB_edge,
                                                             gpubuf.lattice, pbc, nn_dist, tol,
                                                             num_source_inj, num_ground_ext, num_layers_contact,
                                                             num_metals, matrix_size, neighbor_nnz_per_row_d);
    gpuErrchk( hipPeekAtLastError() );
    hipDeviceSynchronize();

    // compute the row pointers with an inclusive sum:
    int *neighbor_row_ptr_d;
    gpuErrchk( hipMalloc((void **)&neighbor_row_ptr_d, (matrix_size + 1 - 1) * sizeof(int)) );
    gpuErrchk( hipMemset(neighbor_row_ptr_d, 0, (matrix_size + 1 - 1) * sizeof(int)) );
    
    void     *temp_storage_d = NULL;                                                          // determines temporary device storage requirements for inclusive prefix sum
    size_t   temp_storage_bytes = 0;
    hipcub::DeviceScan::InclusiveSum(temp_storage_d, temp_storage_bytes, neighbor_nnz_per_row_d, neighbor_row_ptr_d+1, matrix_size - 1); // subtract 1 to ignore the ground node
    gpuErrchk( hipMalloc(&temp_storage_d, temp_storage_bytes) );                             // inclusive sum starting at second value to get the row ptr, which is the same as inclusive sum starting at first value and last value filled with nnz
    hipcub::DeviceScan::InclusiveSum(temp_storage_d, temp_storage_bytes, neighbor_nnz_per_row_d, neighbor_row_ptr_d+1, matrix_size - 1);
    
    // get the number of nonzero elements:
    int neighbor_nnz;
    gpuErrchk( hipMemcpy(&neighbor_nnz, neighbor_row_ptr_d + matrix_size - 1, sizeof(int), hipMemcpyDeviceToHost) );
    std::cout << "\nsparse nnz: " << neighbor_nnz << std::endl;

    // assemble the column indices from 0 to Nsub (excluding the ground node)
    int *neighbor_col_indices_d;
    gpuErrchk( hipMalloc((void **)&neighbor_col_indices_d, neighbor_nnz * sizeof(int)) );
    hipLaunchKernelGGL(calc_col_idx_T_neighbor, num_blocks, num_threads, 0, 0, gpubuf.atom_x, gpubuf.atom_y, gpubuf.atom_z,
                                                         gpubuf.metal_types, gpubuf.atom_element, gpubuf.atom_charge, gpubuf.atom_CB_edge,
                                                         gpubuf.lattice, pbc, nn_dist, tol,
                                                         num_source_inj, num_ground_ext, num_layers_contact,
                                                         num_metals, matrix_size, neighbor_nnz_per_row_d,
                                                         neighbor_row_ptr_d, neighbor_col_indices_d);
    gpuErrchk( hipPeekAtLastError() );
    hipDeviceSynchronize();

    auto tx2 = std::chrono::steady_clock::now();
    std::chrono::duration<double> dtx2 = tx2 - tx1;
    std::cout << "time to assemble the sparse matrix (not included): " << dtx2.count() << "\n";

    // **************************************************************************
    // 4. Populate the entries of the sparse Natom matrix

    double *neighbor_data_d;
    gpuErrchk(hipMalloc((void **)&neighbor_data_d, neighbor_nnz * sizeof(double)));
    gpuErrchk(hipMemset(neighbor_data_d, 0, neighbor_nnz * sizeof(double)));

    num_threads = 512;
    num_blocks = (Nfull + num_threads - 1) / num_threads;
    hipLaunchKernelGGL(populate_data_T_neighbor, num_blocks, num_threads, 0, 0, gpubuf.atom_x, gpubuf.atom_y, gpubuf.atom_z,
                                                          gpubuf.metal_types, gpubuf.atom_element, gpubuf.atom_charge, gpubuf.atom_CB_edge,
                                                          gpubuf.lattice, pbc, nn_dist, tol, high_G, low_G, loop_G,
                                                          Vd, m_e, V0,
                                                          num_source_inj, num_ground_ext, num_layers_contact,
                                                          num_metals, Nfull, neighbor_row_ptr_d, neighbor_col_indices_d, neighbor_data_d);
    gpuErrchk( hipPeekAtLastError() );
    hipDeviceSynchronize();

    auto txx1 = std::chrono::steady_clock::now();
    std::chrono::duration<double> dtxx1 = txx1 - tx2;
    std::cout << "--> time to populate the sparse matrix (included): " << dtxx1.count() << "\n";
    

    // the Nsub matrix of just the sparse neighbor connections is contained in [neighbor_row_ptr_d, neighbor_col_indices_d, neighbor_data_d]

    // *************************************************************************************************************************************
    // 5. Populate the dense matrix corresponding to all of the tunnel connections, using tunnel_indices to index the atom attributes arrays

    double *tunnel_matrix_d;
    gpuErrchk(hipMalloc((void **)&tunnel_matrix_d, num_tunnel_points * num_tunnel_points * sizeof(double)));
    gpuErrchk(hipMemset(tunnel_matrix_d, 0, num_tunnel_points * num_tunnel_points * sizeof(double)));

    num_threads = 512;
    num_blocks = (num_tunnel_points + num_threads - 1) / num_threads;
    hipLaunchKernelGGL(populate_data_T_tunnel, num_blocks, num_threads, 0, 0, tunnel_matrix_d, gpubuf.atom_x, gpubuf.atom_y, gpubuf.atom_z,
                                                        gpubuf.metal_types, gpubuf.atom_element, gpubuf.atom_charge, gpubuf.atom_CB_edge,
                                                        gpubuf.lattice, pbc, high_G, low_G, loop_G, nn_dist, m_e, V0,
                                                        num_source_inj, num_ground_ext, num_layers_contact, N_atom, num_tunnel_points, tunnel_indices,
                                                        num_metals, Vd, tol);
    gpuErrchk( hipPeekAtLastError() );
    hipDeviceSynchronize();

    auto txx2 = std::chrono::steady_clock::now();
    std::chrono::duration<double> dtxx2 = txx2 - txx1;
    std::cout << "--> time to populate the tunnel matrix (included): " << dtxx2.count() << "\n";

    // **************************************************************************
    // 6. Reduce the diagonals
    // the size of the sparse neighbor matrix is Nfull - 1
    // TODO: use better naming of the matrix sizes!!
    double *diagonal_d;
    gpuErrchk( hipMalloc((void **)&diagonal_d, submatrix_size * sizeof(double)) );
    gpuErrchk( hipMemset(diagonal_d, 0, submatrix_size * sizeof(double) ) );

    // reduce the diagonal for the sparse banded matrix
    num_threads = 512;
    num_blocks = (Nfull + num_threads - 1) / num_threads;
    hipLaunchKernelGGL(calc_diagonal_T_gpu, num_blocks, num_threads, 0, 0, neighbor_col_indices_d, neighbor_row_ptr_d, neighbor_data_d, Nfull, diagonal_d);
    gpuErrchk( hipPeekAtLastError() );
    hipDeviceSynchronize();

    // output sparsity of neighbor connections
    // dump_csr_matrix_txt(submatrix_size, neighbor_nnz, neighbor_row_ptr_d, neighbor_col_indices_d, neighbor_data_d, 0);
    // std::cout << "dumped sparse neighbor matrix\n";
    // exit(1);


    // double *diagonal_inv_h = (double *)calloc(submatrix_size, sizeof(double));
    // gpuErrchk( hipMemcpy(diagonal_inv_h, diagonal_d, submatrix_size * sizeof(double), hipMemcpyDeviceToHost) );
    // std::ofstream file("neighbor_diag_soln.txt");
    // if (file.is_open()) {
    //     for (int i = 0; i < submatrix_size; i++) {
    //         file << diagonal_inv_h[i] << " ";
    //     }
    //     file.close();
    // } else {
    //     std::cout << "Unable to open file";
    // }
    // std::cout << "dumped diag aolution\n";
    // exit(1);

    auto txx3 = std::chrono::steady_clock::now();
    std::chrono::duration<double> dtxx3 = txx3 - txx2;
    std::cout << "--> time to reduce the diagonal of the sparse matrix (included): " << dtxx3.count() << "\n";

    // reduce the diagonal for the dense tunnel matrix
    double *tunnel_diag_d;
    gpuErrchk( hipMalloc((void **)&tunnel_diag_d, num_tunnel_points * sizeof(double)) );                              // diagonal elements of the transmission matrix
    gpuErrchk( hipMemset(tunnel_diag_d, 0, num_tunnel_points * sizeof(double)) );

    num_threads = 512;
    int blocks_per_row = (num_tunnel_points - 1) / num_threads + 1;
    num_blocks = blocks_per_row * (N_atom + 2);

    row_reduce<NUM_THREADS><<<num_blocks, num_threads, NUM_THREADS * sizeof(double)>>>(tunnel_matrix_d, tunnel_diag_d, num_tunnel_points);
    gpuErrchk( hipPeekAtLastError() );
    hipDeviceSynchronize();

    auto txx4x = std::chrono::steady_clock::now();
    std::chrono::duration<double> dtxx4x = txx4x - txx3;
    std::cout << "--> --> time to reduce the diagonal of the dense submatrix (included): " << dtxx4x.count() << "\n";

    hipLaunchKernelGGL(write_to_diag_T, blocks_per_row, num_threads, 0, 0, tunnel_matrix_d, tunnel_diag_d, num_tunnel_points);
    gpuErrchk( hipPeekAtLastError() );
    hipDeviceSynchronize();


    auto txx5x = std::chrono::steady_clock::now();
    std::chrono::duration<double> dtxx5x = txx5x - txx4x;
    std::cout << "--> --> time for write_to_diag_T (included): " << dtxx5x.count() << "\n";

    auto txx4 = std::chrono::steady_clock::now();
    std::chrono::duration<double> dtxx4 = txx4 - txx3;
    std::cout << "--> time to reduce the diagonal of the dense submatrix (included): " << dtxx4.count() << "\n";


    //diagonal_d contains already the diagonal of the neighbor matrix
    hipLaunchKernelGGL(extract_diag_tunnel, blocks_per_row, num_threads, 0, 0, 
        tunnel_matrix_d,
        tunnel_indices, 
        num_tunnel_points,
        diagonal_d);
        
    num_threads = 512;
    num_blocks = (submatrix_size + num_threads - 1) / num_threads;
    hipLaunchKernelGGL(inverse_vector, blocks_per_row, num_threads, 0, 0, diagonal_d, submatrix_size);

    auto txx5 = std::chrono::steady_clock::now();
    std::chrono::duration<double> dtxx5 = txx5 - txx4;
    std::cout << "--> time to extract the diagonal for the preconditioner (included): " << dtxx5.count() << "\n";

    // // dump diagonal_d to file:
    // double *diagonal_inv_h = (double *)calloc(submatrix_size, sizeof(double));
    // gpuErrchk( hipMemcpy(diagonal_inv_h, diagonal_d, submatrix_size * sizeof(double), hipMemcpyDeviceToHost) );
    // std::ofstream file("neighbor_diag_soln.txt");
    // if (file.is_open()) {
    //     for (int i = 0; i < submatrix_size; i++) {
    //         file << diagonal_inv_h[i] << " ";
    //     }
    //     file.close();
    // } else {
    //     std::cout << "Unable to open file";
    // }
    // std::cout << "dumped diag aolution\n";
    // exit(1);
    


    // debug
    // double *cpu_T = new double[num_tunnel_points * num_tunnel_points];
    // hipMemcpy(cpu_T, tunnel_matrix_d, sizeof(double) * num_tunnel_points * num_tunnel_points, hipMemcpyDeviceToHost);
    // std::cout << "printing tunnel matrix\n";
    // std::ofstream fout2("T.txt");
    // int row, col;
    // for (row = 0; row < num_tunnel_points; row++) {
    // for (col = 0; col < num_tunnel_points; col++) {
    //     fout2 << cpu_T[row * num_tunnel_points + col] << ' ';
    // }
    // fout2 << '\n';
    // }
    // fout2.close(); 
    // // debug end
    // std::cout << "seomthing" << std::endl;
    // exit(1);
    // debug
    
    double *diagonal_inv_d = diagonal_d;

    auto tx4 = std::chrono::steady_clock::now();
    std::chrono::duration<double> dtx4 = tx4 - tx2;
    std::cout << "total time to build the dense submatrix and populate both matrices (included): " << dtx4.count() << "\n";

    // double *diagonal_inv_h = (double *)calloc(Nfull, sizeof(double));
    // gpuErrchk( hipMemcpy(diagonal_inv_h, diagonal_inv_d, Nfull * sizeof(double), hipMemcpyDeviceToHost) );
    // for (int i = 0; i < Nfull; i++){
    //     std::cout << diagonal_inv_h[i] << " ";
    // }   
    // std::cout << "\n";
    // exit(1);

    // the sparse matrix of the neighbor connectivity is contained in [neighbor_row_ptr_d, neighbor_col_indices_d, neighbor_data_d]
    // the dense matrix of the non-neighbor connectivity is contained in [tunnel_matrix_d] with size num_tunnel_points
    // To build the full matrix, row i and column i of tunnel_matrix_d should be added to row tunnel_indices[i] and col tunnel_indices[i] of the neighbor matrix

    // // output sparsity of neighbor connections
    // dump_csr_matrix_txt(submatrix_size, neighbor_nnz, neighbor_row_ptr_d, neighbor_col_indices_d, neighbor_data_d, 0);
    // std::cout << "dumped sparse neighbor matrix\n";
    // exit(1);

    // debug
    // double *cpu_T = new double[num_tunnel_points * num_tunnel_points];
    // hipMemcpy(cpu_T, tunnel_matrix_d, sizeof(double) * num_tunnel_points * num_tunnel_points, hipMemcpyDeviceToHost);
    // std::cout << "printing tunnel matrix\n";
    // std::ofstream fout2("T.txt");
    // int row, col;
    // for (row = 0; row < num_tunnel_points; row++) {
    // for (col = 0; col < num_tunnel_points; col++) {
    //     fout2 << cpu_T[row * num_tunnel_points + col] << ' ';
    // }
    // fout2 << '\n';
    // }
    // fout2.close(); 
    // // debug end
    // exit(1);

    //debug
    // int *check_tunnel_inds = new int[num_tunnel_points];
    // gpuErrchk( hipMemcpy(check_tunnel_inds, tunnel_indices, num_tunnel_points * sizeof(int), hipMemcpyDeviceToHost) );
    // std::cout << "printing tunnel indices\n";
    // std::ofstream fout("insertion_indices.txt");
    // for (int i = 0; i < num_tunnel_points; i++)
    // {
    //     fout << check_tunnel_inds[i] << ' ';
    // }
    // fout.close(); 
    //debug end

    // results of debug: checked against the full sparse assembly by reassembling the matrix in a python script 

    std::cout << "matrix population is done\n";
    // exit(1);

    // **************************************************************************
    // 7. Prepare the RHS vector

    double *gpu_m;
    gpuErrchk( hipMalloc((void **)&gpu_m, (N_atom + 2) * sizeof(double)) );                                 // [] current injection vector
    gpuErrchk( hipMemset(gpu_m, 0, (N_atom + 2) * sizeof(double)) );                                                                         
    thrust::device_ptr<double> m_ptr = thrust::device_pointer_cast(gpu_m);
    thrust::fill(m_ptr, m_ptr + 1, -loop_G * Vd);                                                            // max Current extraction (ground)                          
    thrust::fill(m_ptr + 1, m_ptr + 2, loop_G * Vd);                                                         // max Current injection (source)
    hipDeviceSynchronize();

    // ************************************************************
    // 8. Solve the system of linear equations 
    
    // the initial guess for the solution is the current site-resolved potential inside the device
    double *gpu_virtual_potentials;
    gpuErrchk( hipMalloc((void **)&gpu_virtual_potentials, (N_atom + 2) * sizeof(double)) );                   // [V] Virtual potential vector  
    gpuErrchk( hipMemset(gpu_virtual_potentials, 0, (N_atom + 2) * sizeof(double)) );                          // initialize the rhs for solving the system                                    
    
    hipsparseHandle_t cusparseHandle;
    hipsparseCreate(&cusparseHandle);
    hipsparseSetPointerMode(cusparseHandle, HIPSPARSE_POINTER_MODE_DEVICE);

    // sparse solver without preconditioning:
    int Nsub = Nfull - 1;
    solve_sparse_CG_splitmatrix(handle, cusparseHandle, tunnel_matrix_d, num_tunnel_points, 
                                neighbor_data_d, neighbor_row_ptr_d, neighbor_col_indices_d, neighbor_nnz, 
                                Nsub, tunnel_indices, gpu_m, gpu_virtual_potentials, diagonal_inv_d);

    gpuErrchk( hipPeekAtLastError() );
    gpuErrchk( hipDeviceSynchronize() );

    double check_element;
    gpuErrchk( hipMemcpy(&check_element, gpu_virtual_potentials + num_source_inj, sizeof(double), hipMemcpyDeviceToHost) );
    if (std::abs(check_element - Vd) > 0.1)
    {
        std::cout << "WARNING: non-negligible potential drop of " << std::abs(check_element - Vd) <<
                    " across the contact at VD = " << Vd << "\n";
    }

    std::cout << "done system solve\n";
    // exit(1);

    // print solution vector to file:
    double *solution = (double *)malloc(Nfull * sizeof(double));
    gpuErrchk( hipMemcpy(solution, gpu_virtual_potentials, Nfull * sizeof(double), hipMemcpyDeviceToHost) );
    std::ofstream fout("virtual_potential_solution.txt");
    for (int i = 0; i < Nfull; i++)
    {
        fout << solution[i] << "\n";
    }
    fout.close();
    std::cout << "solution vectordumped to file\n";
    exit(1);


    // auto t4 = std::chrono::steady_clock::now();
    // std::chrono::duration<double> dt3 = t4 - t3;
    // std::cout << "time to solve linear system: " << dt3.count() << "\n";


    // // ****************************************************
    // // 3. Calculate the net current flowing into the device
    double *gpu_imacro;
    gpuErrchk( hipMalloc((void **)&gpu_imacro, 1 * sizeof(double)) );                                       // [A] The macroscopic device current
    hipDeviceSynchronize();

    // // scale the virtual potentials by G0 (conductance quantum) instead of multiplying inside the X matrix
    thrust::device_ptr<double> gpu_virtual_potentials_ptr = thrust::device_pointer_cast(gpu_virtual_potentials);
    thrust::transform(gpu_virtual_potentials_ptr, gpu_virtual_potentials_ptr + N_atom + 2, gpu_virtual_potentials_ptr, thrust::placeholders::_1 * G0);

    // // macroscopic device current
    gpuErrchk( hipMemset(gpu_imacro, 0, sizeof(double)) ); 
    hipDeviceSynchronize();

    // // dot product of first row of X[i] times M[0] - M[i]
    num_threads = 512;
    num_blocks = (N_atom - 1) / num_threads + 1;
    get_imacro_sparse<NUM_THREADS><<<num_blocks, num_threads, NUM_THREADS * sizeof(double)>>>(
        neighbor_data_d, neighbor_row_ptr_d, neighbor_col_indices_d, gpu_virtual_potentials, gpu_imacro);
    gpuErrchk( hipPeekAtLastError() );
    hipDeviceSynchronize();

    gpuErrchk( hipMemcpy(imacro, gpu_imacro, sizeof(double), hipMemcpyDeviceToHost) );

    // implement the heating calculation (possible from the splitting)
    // ineg would be possible the following way: -aij*xij so -aij xsparseij - aij xdenseij

    std::cout << "I_macro: " << *imacro * (1e6) << "\n";
    // std::cout << "exiting after I_macro\n"; exit(1);

    // hipFree(X_data);
    // hipFree(X_data_copy);
    // hipFree(X_row_ptr);
    // hipFree(X_col_indices);
    // hipFree(gpu_virtual_potentials);
    // hipFree(gpu_imacro);
    // hipFree(gpu_m);
    // hipFree(gpu_index);
    // hipFree(atom_gpu_index);
}

// *** FULL SPARSE MATRIX VERSION ***



// does not assume that the column indices are sorted
__global__ void set_ineg_sparse(double *ineg_values, int *ineg_row_ptr, int *ineg_col_indices, const double *x_values, const int *x_row_ptr, const int *x_col_indices, const double *m, double Vd, int N)
{
    int tid_total = blockIdx.x * blockDim.x + threadIdx.x;
    int num_threads_total = blockDim.x * gridDim.x;

    for (auto i = tid_total; i < N; i += num_threads_total)
    {
        for( int j = ineg_row_ptr[i]; j < ineg_row_ptr[i+1]; j++ )
        {
            if (ineg_col_indices[j] >= 2)
            {
                ineg_values[j] = 0.0;

                double ical = x_values[j] * (m[i + 2] - m[ineg_col_indices[j] + 2]);

                if (ical < 0 && Vd > 0)
                {
                    ineg_values[j] = -ical;
                }
                else if (ical > 0 && Vd < 0)
                {
                    ineg_values[j] = -ical;
                }
            }
        }
    }
}


// assemble the data for the X matrix - 1D distribution over rows
__global__ void populate_T_dist(const double *posx_d, const double *posy_d, const double *posz_d,
                                const ELEMENT *metals, const ELEMENT *element, const int *atom_charge, const double *atom_CB_edge,
                                double nn_dist, const double tol,
                                const double high_G, const double low_G, const double loop_G, 
                                const double Vd, const double m_e, const double V0,
                                int num_source_inj, int num_ground_ext, const int num_layers_contact,
                                int num_metals, int matrix_size, int *col_indices_d, int *row_ptr_d, double *data_d,
                                int size_i, int size_j, int start_i, int start_j)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    int Nsub = matrix_size;
    int N_atom = matrix_size - 1;
    
    for(int id = idx; id < size_i; id += blockDim.x * gridDim.x){
        for( int jd = row_ptr_d[id]; jd < row_ptr_d[id+1]; jd++ )
        {
            int i = start_i + id;
            int j = start_j + col_indices_d[jd];

            // col_indices_d[j] is the index of j in the matrix. j is the index of the data vector
            // if dealing with a diagonal element, we add the positive value from i = i and j = N_full to include the ground node

            // extraction boundary (row)
            if(i == 0)
            {
                // diagonal element (0, 0) --> add the value from (0, N_full)
                if (j == 0)
                {
                    data_d[jd] = +high_G;
                }
                // loop connection (0, 1)
                else if (j == 1)
                {
                    data_d[jd] = -loop_G;
                }
                // extraction connections from the device
                else
                {
                    data_d[jd] = -high_G;
                }  
            }

            // injection boundary (row)
            if(i == 1)
            {
                // loop connection (1, 0) 
                if (j == 0)
                {
                    data_d[jd] = -loop_G;
                }
                // injection connections to the device
                // else
                if ( j > 1 )
                {
                    data_d[jd] = -high_G;
                } 
            }

            // inner matrix terms
            if (i >= 2)
            {
                // diagonal elements --> add the value from (i - 2, N_full - 2) if site i - 2 neighbors the ground node
                if (i == j)
                {
                    double dist_angstrom = site_dist_gpu(posx_d[i - 2], posy_d[i - 2], posz_d[i - 2],
                                                         posx_d[N_atom-1], posy_d[N_atom-1], posz_d[N_atom-1]);                                   
                    bool neighboring_ground = (dist_angstrom < nn_dist);
                    
                    if (neighboring_ground) 
                    {
                        data_d[jd] = +high_G;     // assuming all the connections to ground come from the right contact
                    } 
                }

                // extraction boundary (column)
                if ( (j == 0) && (i > (Nsub+1) - num_ground_ext) )
                {
                    data_d[jd] = -high_G;
                }

                // injection boundary (column)
                if ( (j == 1) && (i > 1) && (i < num_source_inj + 2) )
                // if ( (j == 1) && (i < num_source_inj + 2) )
                {
                    data_d[jd] = -high_G;
                }

                // off-diagonal inner matrix elements
                if ( (j >= 2) && (j != i)) 
                {

                    double dist_angstrom = site_dist_gpu(posx_d[i - 2], posy_d[i - 2], posz_d[i - 2],
                                                         posx_d[j - 2], posy_d[j - 2], posz_d[j - 2]);                                       
                        
                    bool neighbor = (dist_angstrom < nn_dist);                                                      

                    // // non-neighbor connections
                    // if (!neighbor)
                    // {
                    //     bool any_vacancy1 = element[i - 2] == VACANCY;
                    //     bool any_vacancy2 = element[j - 2] == VACANCY;

                    //     // contacts, excluding the last layer 
                    //     bool metal1p = is_in_array_gpu(metals, element[i-2], num_metals) 
                    //                                     && (i-2 > ((num_layers_contact - 1)*num_source_inj))
                    //                                     && (i-2 < (N_atom - (num_layers_contact - 1)*num_ground_ext)); 

                    //     bool metal2p = is_in_array_gpu(metals, element[j-2], num_metals)
                    //                                     && (j-2 > ((num_layers_contact - 1)*num_source_inj))
                    //                                     && (j-2 < (N_atom - (num_layers_contact - 1)*num_ground_ext));  

                    //     // types of tunnelling conditions considered
                    //     bool trap_to_trap = (any_vacancy1 && any_vacancy2);
                    //     bool contact_to_trap = (any_vacancy1 && metal2p) || (any_vacancy2 && metal1p);
                    //     bool contact_to_contact = (metal1p && metal2p);

                    //     double local_E_drop = atom_CB_edge[i - 2] - atom_CB_edge[j - 2];                // [eV] difference in energy between the two atoms

                    //     // compute the WKB tunneling coefficients for all the tunnelling conditions
                    //     if ((trap_to_trap || contact_to_trap || contact_to_contact)  && (fabs(local_E_drop) > tol))
                    //     {
                                
                    //         double prefac = -(sqrt( 2 * m_e ) / h_bar) * (2.0 / 3.0);           // [s/(kg^1/2 * m^2)] coefficient inside the exponential
                    //         double dist = (1e-10)*dist_angstrom;                                // [m] 3D distance between atoms i and j

                    //         if (contact_to_trap)
                    //         {
                    //             double energy_window = fabs(local_E_drop);                      // [eV] energy window for tunneling from the contacts
                    //             double dV = 0.01;                                               // [V] energy spacing for numerical integration
                    //             // double dE = eV_to_J * dV;                                       // [eV] energy spacing for numerical integration
                    //             double dE = eV_to_J * dV * 10; // NOTE: @Manasa this is a temporary fix to avoid MPI issues!


                    //             // integrate over all the occupied energy levels in the contact
                    //             double T = 0.0;
                    //             for (double iv = 0; iv < energy_window; iv += dE)
                    //             {
                    //                 double E1 = eV_to_J * V0 + iv;                                  // [J] Energy distance to CB before tunnelling
                    //                 double E2 = E1 - fabs(local_E_drop);                            // [J] Energy distance to CB after tunnelling

                    //                 if (E2 > 0)                                                     // trapezoidal potential barrier (low field)                 
                    //                 {                                                           
                    //                     T += exp(prefac * (dist / fabs(local_E_drop)) * ( pow(E1, 1.5) - pow(E2, 1.5) ) );
                    //                 }

                    //                 if (E2 < 0)                                                      // triangular potential barrier (high field)                               
                    //                 {
                    //                     T += exp(prefac * (dist / fabs(local_E_drop)) * ( pow(E1, 1.5) )); 
                    //                 } 
                    //             }
                    //             data_d[jd] = -T;
                    //         } 
                    //         else 
                    //         {
                    //             double E1 = eV_to_J * V0;                                        // [J] Energy distance to CB before tunnelling
                    //             double E2 = E1 - fabs(local_E_drop);                             // [J] Energy distance to CB after tunnelling
                                        
                    //             if (E2 > 0)                                                      // trapezoidal potential barrier (low field)
                    //             {                                                           
                    //                 double T = exp(prefac * (dist / fabs(E1 - E2)) * ( pow(E1, 1.5) - pow(E2, 1.5) ) );
                    //                 data_d[jd] = -T;
                    //             }

                    //             if (E2 < 0)                                                        // triangular potential barrier (high field)
                    //             {
                    //                 double T = exp(prefac * (dist / fabs(E1 - E2)) * ( pow(E1, 1.5) ));
                    //                 data_d[jd] = -T;
                    //             }
                    //         }
                    //     }
                    // }

                    // direct terms
                    if ( neighbor )
                    {
                        // contacts
                        bool metal1 = is_in_array_gpu<ELEMENT>(metals, element[i - 2], num_metals);
                        bool metal2 = is_in_array_gpu<ELEMENT>(metals, element[j - 2], num_metals);

                        // conductive vacancy sites
                        bool cvacancy1 = (element[i - 2] == VACANCY) && (atom_charge[i - 2] == 0);
                        bool cvacancy2 = (element[j - 2] == VACANCY) && (atom_charge[j - 2] == 0);
                        
                        if ((metal1 && metal2) || (cvacancy1 && cvacancy2))
                        {
                            data_d[jd] = -high_G;
                        }
                        else
                        {
                            data_d[jd] = -low_G;
                        }
                    }
                }
            }
        }
    }
}


__global__ void calc_diagonal_X_gpu( 
    int *col_indices,
    int *row_ptr,
    double *data,
    double *inv_diag,
    int matrix_size
)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    for(int i = idx; i < matrix_size; i += blockDim.x * gridDim.x){ 
        //reduce the elements in the row
        double tmp = 0.0;
        for(int j = row_ptr[i]; j < row_ptr[i+1]; j++){
            if(i != col_indices[j]){
                tmp += data[j];
            }
        }

        //write the sum of the off-diagonals onto the existing diagonal element
        for(int j = row_ptr[i]; j < row_ptr[i+1]; j++){
            if(i == col_indices[j]){
                data[j] += -tmp;
                inv_diag[i] = 1/data[j];
            }
        }
    }
}


__global__ void calc_diagonal_T( 
    int *col_indices,
    int *row_ptr,
    double *data,
    double *diag,
    int matrix_size,
    int this_ranks_block
)
{   // double check data memset
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    for(int i = idx; i < matrix_size; i += blockDim.x * gridDim.x){ 
        //reduce the elements in the row
        double tmp = 0.0;
        for(int j = row_ptr[i]; j < row_ptr[i+1]; j++){
            if (i != col_indices[j] || this_ranks_block != 0) // check for multiple nodes
            {
                tmp += data[j];
            }
        }
        diag[i] += -tmp;
    }
}

__global__ void insert_diag_T( 
    int *col_indices,
    int *row_ptr,
    double *data,
    double *diag,
    int matrix_size
)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    for(int i = idx; i < matrix_size; i += blockDim.x * gridDim.x){ 

        // write the sum of the off-diagonals onto the existing diagonal element
        for(int j = row_ptr[i]; j < row_ptr[i+1]; j++){
            if(i == col_indices[j]){
                data[j] += diag[i];
                diag[i] = data[j];
            }
        }
    }
}

__global__ void assemble_preconditioner(double *diagonal_local_d, double *diagonal_tunnel_local_d, int *tunnel_indices_local_d, int rows_subblock)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    for(int i = idx; i < rows_subblock; i += blockDim.x * gridDim.x){ 
        // this thread gets an element in diagonal_tunnel_local_d and adds it to diagonal_local_d[tunnel_indices_local_d]:
        diagonal_local_d[tunnel_indices_local_d[i]] += diagonal_tunnel_local_d[i];
    }
}

__global__ void invert_diag(double *diagonal_local_d, int rows_this_rank)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    for(int i = idx; i < rows_this_rank; i += blockDim.x * gridDim.x){ 
        diagonal_local_d[i] = 1/diagonal_local_d[i];
    }
}
    
// updates the atom arrays by filtering the sites:
void update_atom_arrays(GPUBuffers &gpubuf)
{
    int *gpu_index;
    int *atom_gpu_index;
    gpuErrchk( hipMalloc((void **)&gpu_index, gpubuf.N_ * sizeof(int)) );                                           // indices of the site array
    gpuErrchk( hipMalloc((void **)&atom_gpu_index, gpubuf.N_ * sizeof(int)) );                                      // indices of the atom array

    thrust::device_ptr<int> gpu_index_ptr = thrust::device_pointer_cast(gpu_index);
    thrust::sequence(gpu_index_ptr, gpu_index_ptr + gpubuf.N_, 0);

    // std::cout << "updating atom arrays\n";

    double *last_atom = thrust::copy_if(thrust::device, gpubuf.site_x, gpubuf.site_x + gpubuf.N_, gpubuf.site_element, gpubuf.atom_x, is_defect());
    int N_atom = last_atom - gpubuf.atom_x;
    gpubuf.N_atom_ = N_atom;
    thrust::copy_if(thrust::device, gpubuf.site_y, gpubuf.site_y + gpubuf.N_, gpubuf.site_element, gpubuf.atom_y, is_defect());
    thrust::copy_if(thrust::device, gpubuf.site_z, gpubuf.site_z + gpubuf.N_, gpubuf.site_element, gpubuf.atom_z, is_defect());
    thrust::copy_if(thrust::device, gpubuf.site_charge, gpubuf.site_charge + gpubuf.N_, gpubuf.site_element, gpubuf.atom_charge, is_defect());
    thrust::copy_if(thrust::device, gpubuf.site_element, gpubuf.site_element + gpubuf.N_, gpubuf.site_element, gpubuf.atom_element, is_defect());
    thrust::copy_if(thrust::device, gpubuf.site_CB_edge, gpubuf.site_CB_edge + gpubuf.N_, gpubuf.site_element, gpubuf.atom_CB_edge, is_defect());
    thrust::copy_if(thrust::device, gpu_index, gpu_index + gpubuf.N_, gpubuf.site_element, atom_gpu_index, is_defect());

    hipFree(gpu_index);
    hipFree(atom_gpu_index);
}

void populate_data_T_neighbor(GPUBuffers &gpubuf, const double nn_dist, const double tol, const double high_G, const double low_G, const double loop_G, 
                              const double Vd, const double m_e, const double V0, int num_source_inj, int num_ground_ext, int num_layers_contact, int num_metals, int Nsub)
{
    Distributed_matrix *T_distributed = gpubuf.T_distributed;
    int rows_this_rank = T_distributed->rows_this_rank;
    int disp_this_rank = T_distributed->displacements[T_distributed->rank];

    int threads = 1024;
    int blocks = (T_distributed->rows_this_rank + threads - 1) / threads;   

    for(int i = 0; i < T_distributed->number_of_neighbours; i++){

        int rows_neighbour = T_distributed->counts[T_distributed->neighbours[i]];
        int disp_neighbour = T_distributed->displacements[T_distributed->neighbours[i]];

        //check if this memset is needed
        gpuErrchk(hipMemset(T_distributed->data_d[i], 0,
                            T_distributed->nnz_per_neighbour[i] * sizeof(double)) );

        // the T matrix has the additional terms coming from the last column!
        hipLaunchKernelGGL(populate_T_dist, blocks, threads, 0, 0, 
            gpubuf.atom_x, gpubuf.atom_y, gpubuf.atom_z,
            gpubuf.metal_types, gpubuf.atom_element, gpubuf.atom_charge, gpubuf.atom_CB_edge,
            nn_dist, tol, high_G, low_G, loop_G,
            Vd, m_e, V0,
            num_source_inj, num_ground_ext, num_layers_contact, num_metals, Nsub,
            T_distributed->col_indices_d[i],
            T_distributed->row_ptr_d[i],
            T_distributed->data_d[i], 
            rows_this_rank,
            rows_neighbour,
            disp_this_rank,
            disp_neighbour);

    }
}

// reduces the rows of the input sparse matrix into the diagonals, and collects the resulting diagonal vector to be used for preconditioning
void update_diagonal_sparse(GPUBuffers &gpubuf, double *diagonal_local_d)
{
    Distributed_matrix *T_distributed = gpubuf.T_distributed;

    int threads = 1024;
    int blocks = (T_distributed->rows_this_rank + threads - 1) / threads;   

    for(int i = 0; i < T_distributed->number_of_neighbours; i++){
        hipLaunchKernelGGL(calc_diagonal_T, blocks, threads, 0, 0,                             //calc_diagonal_X_gpu
                           T_distributed->col_indices_d[i], 
                           T_distributed->row_ptr_d[i],
                           T_distributed->data_d[i], diagonal_local_d, T_distributed->rows_this_rank, 
                           i);
    }

    // each rank sets its own diagonal (do not set it, the populate-kernel updated the diagonal elements with the last column already)
    hipLaunchKernelGGL(insert_diag_T, blocks, threads, 0, 0,                             
                        T_distributed->col_indices_d[0], 
                        T_distributed->row_ptr_d[0],
                        T_distributed->data_d[0], diagonal_local_d, T_distributed->rows_this_rank);

}


// full sparse matrix assembly
void update_power_gpu_sparse_dist(hipblasHandle_t handle, hipsolverDnHandle_t handle_cusolver, GPUBuffers &gpubuf, 
                                  const int num_source_inj, const int num_ground_ext, const int num_layers_contact,
                                  const double Vd, const double high_G, const double low_G, const double loop_G, const double G0, const double tol,
                                  const double nn_dist, const double m_e, const double V0, int num_metals, double *imacro,
                                  const bool solve_heating_local, const bool solve_heating_global, const double alpha_disp)
{
    int N_atom = gpubuf.N_atom_;
    int Nsub = N_atom + 1;    
    int rank;
    int size;
    
    Distributed_matrix *T_distributed = gpubuf.T_distributed;

    MPI_Comm comm = T_distributed->comm;
    MPI_Comm_rank(comm, &rank);
    MPI_Comm_size(comm, &size);
    int rows_this_rank = T_distributed->rows_this_rank;
    int disp_this_rank = T_distributed->displacements[T_distributed->rank];

    int measurements = 110;
    double time_cg1[measurements];
    double time_cg2[measurements];
    double time_cg3[measurements];
    double time_assemble[measurements];
    // double relative_tolerance = 1e-15 * N_atom; // 1e-26 * N_atom;
    double relative_tolerance = 1e-30 * N_atom;
    int max_iterations = 100; //2000;

    double *virtual_potentials_global_d;
    hipMalloc((void**)&virtual_potentials_global_d, Nsub * sizeof(double));
    

    // the initial guess for the solution is the current site-resolved potential inside the device
    double *gpu_virtual_potentials = gpubuf.atom_virtual_potentials + disp_this_rank;

    double *diagonal_local_d;
    gpuErrchk( hipMalloc((void **)&diagonal_local_d, rows_this_rank* sizeof(double)) );

    double *gpu_imacro, *gpu_m;
    gpuErrchk( hipMalloc((void **)&gpu_imacro, 1 * sizeof(double)) );                                       
    gpuErrchk( hipMalloc((void **)&gpu_m, rows_this_rank * sizeof(double)) );  

    double *diagonal_tunnel_local_d;
    int *row_ptr_subblock_d;
    int *col_indices_subblock_d;
    double *data_d;
    int *tunnel_indices_local_d; // [1, 4...] after shift by 2
    size_t nnz_subblock_local, num_tunnel_points_global;

    int *counts_subblock = new int[size];
    int *displ_subblock = new int[size];

    Distributed_subblock_sparse T_tunnel_distributed;
    T_tunnel_distributed.send_subblock_requests = new MPI_Request[size-1];
    T_tunnel_distributed.recv_subblock_requests = new MPI_Request[size-1];
    T_tunnel_distributed.streams_recv_subblock = new hipStream_t[size-1];
    for(int i = 0; i < size-1; i++){
        hipStreamCreate(&T_tunnel_distributed.streams_recv_subblock[i]);
    }

    for(int i = 0; i < measurements; i++){

        hipDeviceSynchronize();
        MPI_Barrier(comm);
        auto t_start = std::chrono::steady_clock::now();

        // ***************************************************************************************
        // 1. Update the atoms array from the sites array using copy_if with is_defect as a filter
        update_atom_arrays(gpubuf);

        // ***************************************************************************************
        // 2. Populate the sparse neighbor matrix of T:                                                                     // N_full minus the ground node which is cut from the graph
        populate_data_T_neighbor(gpubuf, nn_dist, tol, high_G, low_G, loop_G, Vd, m_e, V0,
            num_source_inj, num_ground_ext, num_layers_contact, num_metals, Nsub);

        // ***************************************************************************************
        // 3. Update the diagonal for the sparse neighbor matrix and collect the preconditioner

        gpuErrchk( hipMemset(diagonal_local_d, 0, rows_this_rank * sizeof(double)) );

        update_diagonal_sparse(gpubuf, diagonal_local_d);

        // std::cout << "Nsub " << Nsub << " nnz " << T_distributed->nnz_per_neighbour[0] << std::endl;
        // dump_csr_matrix_txt(Nsub, T_distributed->nnz_per_neighbour[0], T_distributed->row_ptr_d[0], T_distributed->col_indices_d[0], T_distributed->data_d[0], 4);
        // std::cout << "dumped matrix" << std::endl;
        // exit(1); 

        // ***************************************************************************************
        // 3. Assemble the sparsity for and populate the tunnel submatrix

        int rows_this_rank_tunnel = assemble_sparse_T_submatrix(gpubuf, N_atom, nn_dist, num_source_inj, num_ground_ext, num_layers_contact,
                                                                high_G, low_G, loop_G, Vd, m_e, V0,
                                                                T_tunnel_distributed, T_distributed, 
                                                                diagonal_tunnel_local_d, tunnel_indices_local_d,
                                                                row_ptr_subblock_d, col_indices_subblock_d, data_d, nnz_subblock_local,
                                                                counts_subblock, displ_subblock, num_tunnel_points_global);

        std::cout << "rank " << rank << " Nnz subblock local and num tunnel global " << nnz_subblock_local << " " << num_tunnel_points_global << std::endl;
        // exit(1);

        // subblock creation
        double *tmp_in_d;
        double *tmp_out_d;
        hipMalloc(&tmp_in_d, num_tunnel_points_global * sizeof(double));
        hipMalloc(&tmp_out_d, counts_subblock[rank] * sizeof(double));

        // load data into subblock struct:
        rocsparse_spmat_descr subblock_descriptor;
        rocsparse_dnvec_descr subblock_vector_descriptor_in;
        rocsparse_dnvec_descr subblock_vector_descriptor_out;

        rocsparse_create_dnvec_descr(&subblock_vector_descriptor_in,
                                    num_tunnel_points_global,
                                    tmp_in_d,
                                    rocsparse_datatype_f64_r);

        // Create dense vector Y
        rocsparse_create_dnvec_descr(&subblock_vector_descriptor_out,
                                    counts_subblock[rank],
                                    tmp_out_d,
                                    rocsparse_datatype_f64_r);

        rocsparse_spmv_alg algo = rocsparse_spmv_alg_csr_adaptive;
        // rocsparse_spmv_alg algo = rocsparse_spmv_alg_csr_stream;
        size_t subblock_buffersize;

        rocsparse_create_csr_descr(&subblock_descriptor,
                                    counts_subblock[rank],
                                    num_tunnel_points_global,
                                    nnz_subblock_local,
                                    row_ptr_subblock_d,
                                    col_indices_subblock_d,
                                    data_d,
                                    rocsparse_indextype_i32,
                                    rocsparse_indextype_i32,
                                    rocsparse_index_base_zero,
                                    rocsparse_datatype_f64_r);


        rocsparse_handle rocsparse_handle;
        rocsparse_create_handle(&rocsparse_handle);

        double alpha = 1.0;
        double beta = 0.0;
        rocsparse_spmv(rocsparse_handle,
                        rocsparse_operation_none,
                        &alpha,
                        subblock_descriptor,
                        subblock_vector_descriptor_in,
                        &beta,
                        subblock_vector_descriptor_out,
                        rocsparse_datatype_f64_r,
                        algo,
                        &subblock_buffersize,
                        nullptr);
        double *subblock_buffer_d;
        hipMalloc(&subblock_buffer_d, subblock_buffersize);

        rocsparse_destroy_handle(rocsparse_handle);
        hipFree(tmp_in_d);
        hipFree(tmp_out_d);
        rocsparse_destroy_dnvec_descr(subblock_vector_descriptor_in);
        rocsparse_destroy_dnvec_descr(subblock_vector_descriptor_out);


        // Distributed_subblock_sparse A_subblock;
        T_tunnel_distributed.subblock_indices_local_d = tunnel_indices_local_d;
        T_tunnel_distributed.descriptor = &subblock_descriptor;
        T_tunnel_distributed.algo = algo;
        T_tunnel_distributed.buffersize = &subblock_buffersize;
        T_tunnel_distributed.buffer_d = subblock_buffer_d;
        T_tunnel_distributed.subblock_size = num_tunnel_points_global;
        T_tunnel_distributed.count_subblock_h = counts_subblock;
        T_tunnel_distributed.displ_subblock_h = displ_subblock;


        // subblock creation done

        // ***************************************************************************************
        // 4. Collect the preconditioner (diagonal of the full system)

        // diagonal_local_d is the diagonal of the sparse neighbor matrix
        // diagonal_tunnel_local_d is the diagonal of the sparse neighbor matrix
        // tunnel_indices_local_d are where this rank inserts its diag into diagonal_local_d for the preconditioning

        int threads = 1024;
        int blocks = (T_tunnel_distributed.count_subblock_h[rank] + threads - 1) / threads;
        hipLaunchKernelGGL(assemble_preconditioner, blocks, threads, 0, 0, 
                        diagonal_local_d, diagonal_tunnel_local_d, tunnel_indices_local_d, T_tunnel_distributed.count_subblock_h[rank]);
            
        // invert the diagonal for the preconditioner
        blocks = (rows_this_rank + threads - 1) / threads;
        hipLaunchKernelGGL(invert_diag, blocks, threads, 0, 0, 
                        diagonal_local_d, rows_this_rank);

        // ***************************************************************************************
        // 5. Make the rhs (M) which represents the current inflow/outflow
        gpuErrchk( hipMemset(gpu_m, 0, rows_this_rank * sizeof(double)) );                                        // initialize the rhs for solving the system                                    
        if (!rank)
        {
            thrust::device_ptr<double> m_ptr = thrust::device_pointer_cast(gpu_m);
            thrust::fill(m_ptr, m_ptr + 1, -loop_G * Vd);                                                           // max Current extraction (ground)                          
            thrust::fill(m_ptr + 1, m_ptr + 2, loop_G * Vd);                                                        // max Current injection (source)
        }

        hipDeviceSynchronize();
        MPI_Barrier(comm);
        auto t_end = std::chrono::steady_clock::now();
        time_assemble[i] = std::chrono::duration<double>(t_end - t_start).count();
        if(rank == 0){
            std::cout << "Time taken for assembly " << i << " is " << time_assemble[i] << " seconds" << std::endl;
        }


        if(i < measurements - 1){
            hipFree(T_tunnel_distributed.subblock_indices_local_d);
            hipFree(T_tunnel_distributed.buffer_d);
            rocsparse_destroy_spmat_descr(*T_tunnel_distributed.descriptor);
            hipFree(row_ptr_subblock_d);
            hipFree(col_indices_subblock_d);
            hipFree(data_d);
            hipFree(diagonal_tunnel_local_d);
        }


    }


    double *starting_guess_copy_d;
    double *right_hand_side_copy_d;
    hipMalloc((void**)&starting_guess_copy_d, rows_this_rank * sizeof(double));
    hipMalloc((void**)&right_hand_side_copy_d, rows_this_rank * sizeof(double));
    hipMemcpy(starting_guess_copy_d, gpu_virtual_potentials, rows_this_rank * sizeof(double), hipMemcpyDeviceToDevice);
    hipMemcpy(right_hand_side_copy_d, gpu_m, rows_this_rank * sizeof(double), hipMemcpyDeviceToDevice);


    for(int i = 0; i < measurements; i++){

        hipMemcpy(gpu_virtual_potentials, starting_guess_copy_d, rows_this_rank * sizeof(double), hipMemcpyDeviceToDevice);
        hipMemcpy(gpu_m, right_hand_side_copy_d, rows_this_rank * sizeof(double), hipMemcpyDeviceToDevice);

        hipDeviceSynchronize();
        MPI_Barrier(comm);
        auto t_start = std::chrono::steady_clock::now();
        iterative_solver::conjugate_gradient_jacobi_split_sparse<dspmv_split_sparse::spmm_split_sparse1>(
                        T_tunnel_distributed,
                        *gpubuf.T_distributed,
                        *gpubuf.T_p_distributed,
                        gpu_m,
                        gpu_virtual_potentials,
                        diagonal_local_d,
                        relative_tolerance,
                        max_iterations,
                        comm);
        hipDeviceSynchronize();
        MPI_Barrier(comm);          
        auto t_end = std::chrono::steady_clock::now();
        time_cg1[i] = std::chrono::duration<double>(t_end - t_start).count();
        if(rank == 0){
            std::cout << "Time taken for iteration 1 " << i << " is " << time_cg1[i] << " seconds" << std::endl;
        }
    }
    // for(int i = 0; i < measurements; i++){

    //     hipMemcpy(gpu_virtual_potentials, starting_guess_copy_d, rows_this_rank * sizeof(double), hipMemcpyDeviceToDevice);
    //     hipMemcpy(gpu_m, right_hand_side_copy_d, rows_this_rank * sizeof(double), hipMemcpyDeviceToDevice);

    //     hipDeviceSynchronize();
    //     MPI_Barrier(comm);
    //     auto t_start = std::chrono::steady_clock::now();
    //     iterative_solver::conjugate_gradient_jacobi_split_sparse<dspmv_split_sparse::spmm_split_sparse2>(
    //                     T_tunnel_distributed,
    //                     *gpubuf.T_distributed,
    //                     *gpubuf.T_p_distributed,
    //                     gpu_m,
    //                     gpu_virtual_potentials,
    //                     diagonal_local_d,
    //                     relative_tolerance,
    //                     max_iterations,
    //                     comm);
    //     hipDeviceSynchronize();
    //     MPI_Barrier(comm);          
    //     auto t_end = std::chrono::steady_clock::now();
    //     time_cg2[i] = std::chrono::duration<double>(t_end - t_start).count();
    //     if(rank == 0){
    //         std::cout << "Time taken for iteration 2 " << i << " is " << time_cg2[i] << " seconds" << std::endl;
    //     }
    // }

    for(int i = 0; i < measurements; i++){

        hipMemcpy(gpu_virtual_potentials, starting_guess_copy_d, rows_this_rank * sizeof(double), hipMemcpyDeviceToDevice);
        hipMemcpy(gpu_m, right_hand_side_copy_d, rows_this_rank * sizeof(double), hipMemcpyDeviceToDevice);

        hipDeviceSynchronize();
        MPI_Barrier(comm);
        auto t_start = std::chrono::steady_clock::now();
        iterative_solver::conjugate_gradient_jacobi_split_sparse<dspmv_split_sparse::spmm_split_sparse3>(
                        T_tunnel_distributed,
                        *gpubuf.T_distributed,
                        *gpubuf.T_p_distributed,
                        gpu_m,
                        gpu_virtual_potentials,
                        diagonal_local_d,
                        relative_tolerance,
                        max_iterations,
                        comm);
        hipDeviceSynchronize();
        MPI_Barrier(comm);          
        auto t_end = std::chrono::steady_clock::now();
        time_cg3[i] = std::chrono::duration<double>(t_end - t_start).count();
        if(rank == 0){
            std::cout << "Time taken for iteration 3 " << i << " is " << time_cg3[i] << " seconds" << std::endl;
        }
    }

    if(rank == 0){
        std::string base_path = "current/";
        std::string filename = base_path + "time_cg1_" + std::to_string(T_distributed->size) + ".txt";
        std::ofstream file(filename);
        for(int i = 0; i < measurements; i++){
            file << time_cg1[i] << std::endl;
        }
        file.close();

        // std::string filename1 = base_path + "time_cg2_" + std::to_string(T_distributed->size) + ".txt";
        // std::ofstream file1(filename1);
        // for(int i = 0; i < measurements; i++){
        //     file1 << time_cg2[i] << std::endl;
        // }
        // file1.close();

        std::string filename2 = base_path + "time_cg3_" + std::to_string(T_distributed->size) + ".txt";
        std::ofstream file2(filename2);
        for(int i = 0; i < measurements; i++){
            file2 << time_cg3[i] << std::endl;
        }
        file2.close();

        std::string filename4 = base_path + "time_assemble_" + std::to_string(T_distributed->size) + ".txt";
        std::ofstream file4(filename4);
        for(int i = 0; i < measurements; i++){
            file4 << time_assemble[i] << std::endl;
        }
        file4.close();
    }

    hipFree(starting_guess_copy_d);
    hipFree(right_hand_side_copy_d);


    // this rank updates the global solution vector to use for the next superstep
    MPI_Gatherv(gpu_virtual_potentials, rows_this_rank, MPI_DOUBLE, virtual_potentials_global_d,
        T_distributed->counts, T_distributed->displacements, MPI_DOUBLE, 0, comm);
    

    // debug for solution vector
    // if (!rank)
    // {
    //     // copy back and print the solution vector gpu_virtual_potentials out to a file;
    //     double *virtual_potentials_global_h = (double *)calloc(Nsub, sizeof(double));
    //     gpuErrchk( hipMemcpy(virtual_potentials_global_h, virtual_potentials_global_d, Nsub * sizeof(double), hipMemcpyDeviceToHost) );
    //     std::ofstream file("gpu_virtual_potentials_" + std::to_string(T_distributed->step_count) + ".txt");
    //     for (int i = 0; i < Nsub; i++){
    //         file << virtual_potentials_global_h[i] << " ";
    //     }
    //     file.close();
    //     std::cout << "dumped the solution vector from sparse_dist version\n";
    //     T_distributed->step_count++;
    // }
    MPI_Barrier(comm);
    exit(1);
    // std::cout << "exiting after solving\n"; exit(1);

    // // ****************************************************
    // // 3. Calculate the net current flowing into the device

    // // scale the virtual potentials by G0 (conductance quantum) instead of multiplying inside the X matrix
    // thrust::device_ptr<double> gpu_virtual_potentials_ptr = thrust::device_pointer_cast(gpu_virtual_potentials);
    // thrust::transform(gpu_virtual_potentials_ptr, gpu_virtual_potentials_ptr + N_atom + 2, gpu_virtual_potentials_ptr, thrust::placeholders::_1 * G0);

    // // macroscopic device current
    // gpuErrchk( hipMemset(gpu_imacro, 0, sizeof(double)) ); 
    // hipDeviceSynchronize();

    // // dot product of first row of X[i] times M[0] - M[i]
    // int num_threads = 512;
    // int num_blocks = (N_atom - 1) / num_threads + 1;
    // get_imacro_sparse<NUM_THREADS><<<num_blocks, num_threads, NUM_THREADS * sizeof(double)>>>(T_distributed->data_d[0], T_distributed->row_ptr_d[0], T_distributed->col_indices_d[0], gpu_virtual_potentials, gpu_imacro);
    // gpuErrchk( hipPeekAtLastError() );
    // hipDeviceSynchronize();
    // gpuErrchk( hipMemcpy(imacro, gpu_imacro, sizeof(double), hipMemcpyDeviceToHost) );

    // std::cout << "I_macro: " << *imacro * (1e6) << "\n";
    // std::cout << "exiting after I_macro\n"; exit(1);

    hipFree(gpu_imacro);
    hipFree(gpu_m);
    hipFree(diagonal_local_d);

    hipFree(T_tunnel_distributed.subblock_indices_local_d);
    rocsparse_destroy_spmat_descr(*T_tunnel_distributed.descriptor);
    hipFree(T_tunnel_distributed.buffer_d);
    std::cout << 1 << std::endl;
    delete[] T_tunnel_distributed.count_subblock_h;
    std::cout << 2 << std::endl;
    delete[] T_tunnel_distributed.displ_subblock_h;
    std::cout << 3 << std::endl;
    delete[] T_tunnel_distributed.send_subblock_requests;
    std::cout << 4 << std::endl;
    delete[] T_tunnel_distributed.recv_subblock_requests;

    for (int i = 0; i < size; i++)
    {
        hipStreamDestroy(T_tunnel_distributed.streams_recv_subblock[i]);
    }
    std::cout << 5 << std::endl;
    delete[] T_tunnel_distributed.streams_recv_subblock;
    
    hipFree(row_ptr_subblock_d);
    hipFree(col_indices_subblock_d);
    hipFree(data_d);
    hipFree(tunnel_indices_local_d);
    hipFree(diagonal_tunnel_local_d);
    
}


// full sparse matrix assembly
void update_power_gpu_sparse(hipblasHandle_t handle, hipsolverDnHandle_t handle_cusolver, GPUBuffers &gpubuf, 
                             const int num_source_inj, const int num_ground_ext, const int num_layers_contact,
                             const double Vd, const int pbc, const double high_G, const double low_G, const double loop_G, const double G0, const double tol,
                             const double nn_dist, const double m_e, const double V0, int num_metals, double *imacro,
                             const bool solve_heating_local, const bool solve_heating_global, const double alpha_disp)
{
    auto t0 = std::chrono::steady_clock::now();

    // ***************************************************************************************
    // 1. Update the atoms array from the sites array using copy_if with is_defect as a filter
    int *gpu_index;
    int *atom_gpu_index;
    gpuErrchk( hipMalloc((void **)&gpu_index, gpubuf.N_ * sizeof(int)) );                                           // indices of the site array
    gpuErrchk( hipMalloc((void **)&atom_gpu_index, gpubuf.N_ * sizeof(int)) );                                      // indices of the atom array

    thrust::device_ptr<int> gpu_index_ptr = thrust::device_pointer_cast(gpu_index);
    thrust::sequence(gpu_index_ptr, gpu_index_ptr + gpubuf.N_, 0);

    double *last_atom = thrust::copy_if(thrust::device, gpubuf.site_x, gpubuf.site_x + gpubuf.N_, gpubuf.site_element, gpubuf.atom_x, is_defect());
    int N_atom = last_atom - gpubuf.atom_x;
    thrust::copy_if(thrust::device, gpubuf.site_y, gpubuf.site_y + gpubuf.N_, gpubuf.site_element, gpubuf.atom_y, is_defect());
    thrust::copy_if(thrust::device, gpubuf.site_z, gpubuf.site_z + gpubuf.N_, gpubuf.site_element, gpubuf.atom_z, is_defect());
    thrust::copy_if(thrust::device, gpubuf.site_charge, gpubuf.site_charge + gpubuf.N_, gpubuf.site_element, gpubuf.atom_charge, is_defect());
    thrust::copy_if(thrust::device, gpubuf.site_element, gpubuf.site_element + gpubuf.N_, gpubuf.site_element, gpubuf.atom_element, is_defect());
    thrust::copy_if(thrust::device, gpubuf.site_CB_edge, gpubuf.site_CB_edge + gpubuf.N_, gpubuf.site_element, gpubuf.atom_CB_edge, is_defect());
    thrust::copy_if(thrust::device, gpu_index, gpu_index + gpubuf.N_, gpubuf.site_element, atom_gpu_index, is_defect());

    auto t1 = std::chrono::steady_clock::now();
    std::chrono::duration<double> dt = t1 - t0;
    std::cout << "time to update atom arrays: " << dt.count() << "\n";

    // ***************************************************************************************
    // 2. Assemble the transmission matrix (X) with both direct and tunnel connections and the
    // solution vector (M) which represents the current inflow/outflow
    // int N_full = N_atom + 2;                                                                               // number of atoms + injection node + extraction node
    int Nsub = N_atom + 1;                                                                                 // N_full minus the ground node which is cut from the graph

    // compute the index arrays to build the CSR representation of X (from 0 to Nsub):
    int *X_row_ptr;
    int *X_col_indices;
    int X_nnz = 0;
    Assemble_X_sparsity(N_atom, gpubuf.atom_x, gpubuf.atom_y, gpubuf.atom_z,
                        gpubuf.metal_types, gpubuf.atom_element, gpubuf.atom_charge, gpubuf.atom_CB_edge,
                        gpubuf.lattice, pbc, nn_dist, tol, 
                        num_source_inj, num_ground_ext, num_layers_contact,
                        num_metals, &X_row_ptr, &X_col_indices, &X_nnz);
    hipDeviceSynchronize();

    // print nnz:
    // std::cout << "X_nnz: " << X_nnz << "\n";
    // std::cout << "Nsub: " << Nsub << "\n";
    // exit(1);

    // get the row indices for COO
    int *X_row_indices_h = new int[X_nnz];
    int *X_row_ptr_h = new int[N_atom + 2];

    gpuErrchk( hipMemcpy(X_row_ptr_h, X_row_ptr, (N_atom + 2) * sizeof(int), hipMemcpyDeviceToHost) );
    for(int i = 0; i < N_atom + 1; i++){
        for(int j = X_row_ptr_h[i]; j < X_row_ptr_h[i+1]; j++){
            X_row_indices_h[j] = i;
        }
    }
    int *X_row_indices;
    gpuErrchk( hipMalloc((void **)&X_row_indices, X_nnz * sizeof(int)) );
    gpuErrchk( hipMemcpy(X_row_indices, X_row_indices_h, X_nnz * sizeof(int), hipMemcpyHostToDevice) );
    free(X_row_indices_h);
    free(X_row_ptr_h);
    
    auto t2 = std::chrono::steady_clock::now();
    std::chrono::duration<double> dt1 = t2 - t1;
    std::cout << "time to assemble X sparsity: " << dt1.count() << "\n";

    // Assemble the nonzero value array of X in CSR (from 0 to Nsub):
    double *X_data;                                                                                             // [1] Transmission matrix
    // Assemble_X(N_atom, gpubuf.atom_x, gpubuf.atom_y, gpubuf.atom_z,
    //            gpubuf.metal_types, gpubuf.atom_element, gpubuf.atom_charge, gpubuf.atom_CB_edge,
    //            gpubuf.lattice, pbc, nn_dist, tol, Vd, m_e, V0, high_G, low_G, loop_G,
    //            num_source_inj, num_ground_ext, num_layers_contact,
    //            num_metals, &X_data, &X_row_ptr, &X_col_indices, &X_nnz);

    // double *X_data2;                                                                                          // [1] Transmission matrix
    Assemble_X2(N_atom, gpubuf.atom_x, gpubuf.atom_y, gpubuf.atom_z,
                gpubuf.metal_types, gpubuf.atom_element, gpubuf.atom_charge, gpubuf.atom_CB_edge,
                gpubuf.lattice, pbc, nn_dist, tol, Vd, m_e, V0, high_G, low_G, loop_G,
                num_source_inj, num_ground_ext, num_layers_contact,
                num_metals, &X_data, &X_row_indices, &X_row_ptr, &X_col_indices, &X_nnz);
    hipDeviceSynchronize();

    // dump_csr_matrix_txt(Nsub, X_nnz, X_row_ptr, X_col_indices, X_data, 0); // figure out why the vector lengths are wrong according to the python script
    // std::cout << "dumped original sparse T matrix\n";

    // exit(1);
    
    // gpuErrchk( hipFree(X_row_indices) );
    // double *X_data_h = new double[X_nnz];
    // double *X_data2_h = new double[X_nnz];
    // gpuErrchk( hipMemcpy(X_data_h, X_data, X_nnz * sizeof(double), hipMemcpyDeviceToHost) );
    // gpuErrchk( hipMemcpy(X_data2_h, X_data2, X_nnz * sizeof(double), hipMemcpyDeviceToHost) );

    // for (int i = 0; i < X_nnz; i++)
    // {

    //     // if (X_data_h[i] == X_data2_h[i])
    //     // {
    //     //     std::cout << "X_data match at index " << i << " with value " << X_data_h[i] << "\n";
    //     // }
    //     if (X_data_h[i] != X_data2_h[i])
    //     {
    //         std::cout << "X_data mismatch at index " << i << " with values " << X_data_h[i] << " and " << X_data2_h[i] << "\n";
    //     }
    // }

    auto t3 = std::chrono::steady_clock::now();
    std::chrono::duration<double> dt2 = t3 - t2;
    std::cout << "time to assemble X data: " << dt2.count() << "\n";

    double *gpu_imacro, *gpu_m;
    gpuErrchk( hipMalloc((void **)&gpu_imacro, 1 * sizeof(double)) );                                       // [A] The macroscopic device current
    gpuErrchk( hipMalloc((void **)&gpu_m, (N_atom + 2) * sizeof(double)) );                                 // [V] Virtual potential vector    
    hipDeviceSynchronize();

    gpuErrchk( hipMemset(gpu_m, 0, (N_atom + 2) * sizeof(double)) );                                        // initialize the rhs for solving the system                                    
    thrust::device_ptr<double> m_ptr = thrust::device_pointer_cast(gpu_m);
    thrust::fill(m_ptr, m_ptr + 1, -loop_G * Vd);                                                            // max Current extraction (ground)                          
    thrust::fill(m_ptr + 1, m_ptr + 2, loop_G * Vd);                                                         // max Current injection (source)
    hipDeviceSynchronize();

    // std::cout << "norm of the rhs:\n";
    // double t;
    // CheckCublasError( hipblasDdot (handle, Nsub, gpu_m, 1, gpu_m, 1, &t) );
    // std::cout << t << "\n";
    // exit(1);

    // ************************************************************
    // 2. Solve system of linear equations 
    
    // the initial guess for the solution is the current site-resolved potential inside the device
    double *gpu_virtual_potentials = gpubuf.atom_virtual_potentials;                                         // [V] Virtual potential vector  
    
    // making a copy so the original version won't be preconditioned inside the iterative solver
    double *X_data_copy;
    gpuErrchk( hipMalloc((void **)&X_data_copy, X_nnz * sizeof(double)) );
    gpuErrchk( hipMemcpyAsync(X_data_copy, X_data, X_nnz * sizeof(double), hipMemcpyDeviceToDevice) ); 
    gpuErrchk( hipDeviceSynchronize() );

    hipsparseHandle_t cusparseHandle;
    hipsparseCreate(&cusparseHandle);
    hipsparseSetPointerMode(cusparseHandle, HIPSPARSE_POINTER_MODE_DEVICE);

    // sparse solver with Jacobi preconditioning:
    solve_sparse_CG_Jacobi(handle, cusparseHandle, X_data_copy, X_row_ptr, X_col_indices, X_nnz, Nsub, gpu_m, gpu_virtual_potentials);
    gpuErrchk( hipPeekAtLastError() );
    gpuErrchk( hipDeviceSynchronize() );

    double check_element;
    gpuErrchk( hipMemcpy(&check_element, gpu_virtual_potentials + num_source_inj, sizeof(double), hipMemcpyDeviceToHost) );
    if (std::abs(check_element - Vd) > 0.1)
    {
        std::cout << "WARNING: non-negligible potential drop of " << std::abs(check_element - Vd) <<
                    " across the contact at VD = " << Vd << "\n";
    }

    auto t4 = std::chrono::steady_clock::now();
    std::chrono::duration<double> dt3 = t4 - t3;
    std::cout << "time to solve linear system: " << dt3.count() << "\n";

    // dump solution vector to file:
    double *virtual_potentials_h = (double *)calloc(N_atom + 2, sizeof(double));
    gpuErrchk( hipMemcpy(virtual_potentials_h, gpu_virtual_potentials, (N_atom + 2) * sizeof(double), hipMemcpyDeviceToHost) );
    std::ofstream file("gpu_virtual_potentials_og.txt");
    for (int i = 0; i < N_atom + 2; i++){
        file << virtual_potentials_h[i] << " ";
    }
    exit(1);

    // ****************************************************
    // 3. Calculate the net current flowing into the device

    // scale the virtual potentials by G0 (conductance quantum) instead of multiplying inside the X matrix
    thrust::device_ptr<double> gpu_virtual_potentials_ptr = thrust::device_pointer_cast(gpu_virtual_potentials);
    thrust::transform(gpu_virtual_potentials_ptr, gpu_virtual_potentials_ptr + N_atom + 2, gpu_virtual_potentials_ptr, thrust::placeholders::_1 * G0);

    // macroscopic device current
    gpuErrchk( hipMemset(gpu_imacro, 0, sizeof(double)) ); 
    hipDeviceSynchronize();

    // dot product of first row of X[i] times M[0] - M[i]
    int num_threads = 512;
    int num_blocks = (N_atom - 1) / num_threads + 1;
    get_imacro_sparse<NUM_THREADS><<<num_blocks, num_threads, NUM_THREADS * sizeof(double)>>>(X_data, X_row_ptr, X_col_indices, gpu_virtual_potentials, gpu_imacro);
    gpuErrchk( hipPeekAtLastError() );
    hipDeviceSynchronize();

    gpuErrchk( hipMemcpy(imacro, gpu_imacro, sizeof(double), hipMemcpyDeviceToHost) );

    auto t5 = std::chrono::steady_clock::now();
    std::chrono::duration<double> dt4 = t5 - t4;
    std::cout << "time to compute current: " << dt4.count() << "\n";

    std::cout << "I_macro: " << *imacro * (1e6) << "\n";
    // std::cout << "exiting after I_macro\n"; exit(1);

    // **********************************************
    // 4. Calculate the dissipated power at each atom

if (solve_heating_local || solve_heating_global)
{    
    // Shift the virtual potential so that it is all positive, as we will take differences
    double min_index = thrust::min_element(thrust::device, gpu_virtual_potentials + 2, gpu_virtual_potentials + N_atom + 2) - gpu_virtual_potentials;
    num_threads = 512;
    num_blocks = (N_atom + 2 - 1) / num_threads + 1;
    hipLaunchKernelGGL(update_m, num_blocks, num_threads, 0, 0, gpu_virtual_potentials, min_index, N_atom + 2);
    gpuErrchk( hipPeekAtLastError() );

    // Collect the forward currents into I_neg, the diagonals are once again the sum of each row
    int *ineg_row_ptr;                                                                                          // [A] Current inflow matrix
    int *ineg_col_indices;
    double *ineg_data;
    gpuErrchk( hipMalloc((void**) &ineg_row_ptr, (N_atom + 1 + 1) * sizeof(int)) );
    gpuErrchk( hipMalloc((void**) &ineg_col_indices, X_nnz * sizeof(int)) );
    gpuErrchk( hipMalloc((void **)&ineg_data, X_nnz * sizeof(double)) );
    gpuErrchk( hipMemcpyAsync(ineg_row_ptr, X_row_ptr, (N_atom + 1 + 1) * sizeof(int), hipMemcpyDeviceToDevice) );
    gpuErrchk( hipMemcpyAsync(ineg_col_indices, X_col_indices, X_nnz * sizeof(int), hipMemcpyDeviceToDevice) );
    gpuErrchk( hipMemset(ineg_data, 0, X_nnz*sizeof(double)) ); 
    hipDeviceSynchronize();

    num_threads = 512;
    num_blocks = (Nsub - 1) / num_threads + 1;
    int N_atomsub = N_atom - 1;
    hipLaunchKernelGGL(set_ineg_sparse, num_blocks, num_threads, 0, 0, ineg_data, ineg_row_ptr, ineg_col_indices, X_data, X_row_ptr, X_col_indices, gpu_virtual_potentials, Vd, N_atomsub);
    gpuErrchk( hipPeekAtLastError() );
    hipDeviceSynchronize();

    // sum off-diagonals into diagonal:
    num_threads = 512;
    num_blocks = (Nsub - 1) / num_threads + 1;
    hipLaunchKernelGGL(reduce_rows_into_diag, num_blocks, num_threads, 0, 0, ineg_col_indices, ineg_row_ptr, ineg_data, Nsub);
    gpuErrchk( hipPeekAtLastError() );
    hipDeviceSynchronize();

    // Compute the dissipated power at each atom with [P]_Nx1 = [I]_NxN * [V]_Nx1 (gemv --> spmv)
    double *gpu_pdisp;
    gpuErrchk( hipMalloc((void **)&gpu_pdisp, N_atom * sizeof(double)) );                                   // [W] Dissipated power vector
    gpuErrchk( hipMemset(gpu_pdisp, 0, N_atom*sizeof(double)) ); 

    hipsparseStatus_t status;
    hipsparseSpMatDescr_t mat_ineg;
    status = hipsparseCreateCsr(&mat_ineg, Nsub, Nsub, X_nnz, ineg_row_ptr, ineg_col_indices, ineg_data, 
                               HIPSPARSE_INDEX_32I, HIPSPARSE_INDEX_32I, HIPSPARSE_INDEX_BASE_ZERO, HIP_R_64F);
    if (status != HIPSPARSE_STATUS_SUCCESS)
    {
        std::cout << "ERROR: creation of sparse matrix descriptor in update_power_gpu_sparse() failed!\n";
    }
    hipsparseDnVecDescr_t vec_virtual_potentials, vec_pdisp;
    hipsparseCreateDnVec(&vec_virtual_potentials, Nsub, gpu_virtual_potentials, HIP_R_64F);
    hipsparseCreateDnVec(&vec_pdisp, Nsub, gpu_pdisp, HIP_R_64F);

    size_t MVBufferSize;
    void *MVBuffer = 0;
    double *one_d, *zero_d;
    double one = 1.0;
    double zero = 0.0;
    gpuErrchk( hipMalloc((void**)&one_d, sizeof(double)) );
    gpuErrchk( hipMalloc((void**)&zero_d, sizeof(double)) );
    gpuErrchk( hipMemcpy(one_d, &one, sizeof(double), hipMemcpyHostToDevice) );
    gpuErrchk( hipMemcpy(zero_d, &zero, sizeof(double), hipMemcpyHostToDevice) );

    status = hipsparseSpMV_bufferSize(cusparseHandle, HIPSPARSE_OPERATION_NON_TRANSPOSE, one_d, mat_ineg, 
                                     vec_virtual_potentials, zero_d, vec_pdisp, HIP_R_64F, HIPSPARSE_SPMV_ALG_DEFAULT, &MVBufferSize);  
    gpuErrchk( hipMalloc((void**)&MVBuffer, sizeof(double) * MVBufferSize) );
    status = hipsparseSpMV(cusparseHandle, HIPSPARSE_OPERATION_NON_TRANSPOSE, one_d, mat_ineg,                         
                          vec_virtual_potentials, zero_d, vec_pdisp, HIP_R_64F, HIPSPARSE_SPMV_ALG_DEFAULT, MVBuffer);          
    
    // copy the dissipated power into the site attributes
    num_threads = 512;
    num_blocks = (N_atom - 1) / num_threads + 1;
    num_blocks = min(65535, num_blocks);
    hipLaunchKernelGGL(copy_pdisp, num_blocks, num_threads, 0, 0, gpubuf.site_power, gpubuf.site_element, gpubuf.metal_types, gpu_pdisp, atom_gpu_index, N_atom, num_metals, alpha_disp);
    gpuErrchk( hipPeekAtLastError() );
    hipDeviceSynchronize();

    // !!! the dissipated power does not yet perfectly match the dense version !!!
    // !!! there is probably a small expected change due to removing the ground node, but this should be double checked !!!
    
    // double *host_pdisp = new double[N_atom];
    // hipMemcpy(host_pdisp, gpu_pdisp, N_atom * sizeof(double), hipMemcpyDeviceToHost);
    // double sum = 0.0;
    // for (int i = 0; i < N_atom; ++i) {
    //     sum += host_pdisp[i];
    // }
    // std::cout << "Sum of atom-resolved power: " << sum << std::endl;
    // exit(1);

    hipFree(ineg_row_ptr);
    hipFree(ineg_col_indices);
    hipFree(ineg_data);
    hipFree(gpu_pdisp);
    hipFree(MVBuffer); 
    hipFree(one_d);
    hipFree(zero_d);
}

    hipFree(X_data);
    hipFree(X_data_copy);
    hipFree(X_row_ptr);
    hipFree(X_row_indices);
    hipFree(X_col_indices);
    hipFree(gpu_imacro);
    hipFree(gpu_m);
    hipFree(gpu_index);
    hipFree(atom_gpu_index);
}

// *** DENSE MATRIX VERSION ***

__global__ void create_X(
    double *X,
    const double *posx, const double *posy, const double *posz,
    const ELEMENT *metals, const ELEMENT *element, const int *atom_charge, const double *atom_CB_edge,
    const double *lattice, bool pbc, double high_G, double low_G, double loop_G,
    double nn_dist, double m_e, double V0, int num_source_inj, int num_ground_ext, const int num_layers_contact,
    int N, int num_metals, const double Vd, const double tol)
{

    int tid_total = blockIdx.x * blockDim.x + threadIdx.x;
    int num_threads_total = blockDim.x * gridDim.x;

    int N_full = N + 2;

    // TODO: Does it make sense to restructure for N_full * N_full threads?
    for (auto idx = tid_total; idx < N * N; idx += num_threads_total)
    {
        int i = idx / N;
        int j = idx % N;

        double dist_angstrom = site_dist_gpu(posx[i], posy[i], posz[i], 
                                             posx[j], posy[j], posz[j], 
                                             lattice[0], lattice[1], lattice[2], pbc);

        bool neighbor = (dist_angstrom < nn_dist) && (i != j);

        // tunneling terms occur between not-neighbors
        if (i != j && !neighbor)
        { 
            bool any_vacancy1 = element[i] == VACANCY;
            bool any_vacancy2 = element[j] == VACANCY;

            // contacts, excluding the last layer 
            bool metal1p = is_in_array_gpu(metals, element[i], num_metals) 
                                       && (i > ((num_layers_contact - 1)*num_source_inj))
                                       && (i < (N - (num_layers_contact - 1)*num_ground_ext)); 

            bool metal2p = is_in_array_gpu(metals, element[j], num_metals)
                                       && (j > ((num_layers_contact - 1)*num_source_inj))
                                       && (j < (N - (num_layers_contact - 1)*num_ground_ext));  

            // types of tunnelling conditions considered
            bool trap_to_trap = (any_vacancy1 && any_vacancy2);
            bool contact_to_trap = (any_vacancy1 && metal2p) || (any_vacancy2 && metal1p);
            bool contact_to_contact = (metal1p && metal2p);

            double local_E_drop = atom_CB_edge[i] - atom_CB_edge[j];                // [eV] difference in energy between the two atoms

            // compute the WKB tunneling coefficients for all the tunnelling conditions
            if ((trap_to_trap || contact_to_trap || contact_to_contact)  && (fabs(local_E_drop) > tol))
            {
                
                double prefac = -(sqrt( 2 * m_e ) / h_bar) * (2.0 / 3.0);           // [s/(kg^1/2 * m^2)] coefficient inside the exponential
                double dist = (1e-10)*dist_angstrom;                                // [m] 3D distance between atoms i and j

                if (contact_to_trap)
                {
                    double energy_window = fabs(local_E_drop);                      // [eV] energy window for tunneling from the contacts
                    double dV = 0.01;                                               // [V] energy spacing for numerical integration
                    double dE = eV_to_J * dV;                                       // [eV] energy spacing for numerical integration
                        
                    // integrate over all the occupied energy levels in the contact
                    double T = 0.0;
                    for (double iv = 0; iv < energy_window; iv += dE)
                    {
                        double E1 = eV_to_J * V0 + iv;                                  // [J] Energy distance to CB before tunnelling
                        double E2 = E1 - fabs(local_E_drop);                            // [J] Energy distance to CB after tunnelling

                        if (E2 > 0)                                                     // trapezoidal potential barrier (low field)                 
                        {                                                           
                            T += exp(prefac * (dist / fabs(local_E_drop)) * ( pow(E1, 1.5) - pow(E2, 1.5) ) );
                        }

                        if (E2 < 0)                                                      // triangular potential barrier (high field)                               
                        {
                            T += exp(prefac * (dist / fabs(local_E_drop)) * ( pow(E1, 1.5) )); 
                        } 
                    }
                    X[N_full * (i + 2) + (j + 2)] = -T;      
                } 
                else 
                {
                    double E1 = eV_to_J * V0;                                        // [J] Energy distance to CB before tunnelling
                    double E2 = E1 - fabs(local_E_drop);                             // [J] Energy distance to CB after tunnelling
                          
                    if (E2 > 0)                                                      // trapezoidal potential barrier (low field)
                    {                                                           
                        double T = exp(prefac * (dist / fabs(E1 - E2)) * ( pow(E1, 1.5) - pow(E2, 1.5) ) );
                        X[N_full * (i + 2) + (j + 2)] = -T; 
                    }

                    if (E2 < 0)                                                        // triangular potential barrier (high field)
                    {
                        double T = exp(prefac * (dist / fabs(E1 - E2)) * ( pow(E1, 1.5) ));
                        X[N_full * (i + 2) + (j + 2)] = -T; 
                    }
                }
            }
        }

        // direct terms occur between neighbors 
        if (i != j && neighbor)
        {
            // contacts
            bool metal1 = is_in_array_gpu(metals, element[i], num_metals);
            bool metal2 = is_in_array_gpu(metals, element[j], num_metals);

            // conductive vacancy sites
            bool cvacancy1 = (element[i] == VACANCY) && (atom_charge[i] == 0);
            bool cvacancy2 = (element[j] == VACANCY) && (atom_charge[j] == 0);

            if ((metal1 && metal2) || (cvacancy1 && cvacancy2))
            {
                X[N_full * (i + 2) + (j + 2)] = -high_G;
            }
            else
            {
                X[N_full * (i + 2) + (j + 2)] = -low_G;
            }
        }

        // NOTE: Is there a data race here?
        // connect the source/ground nodes to the first/last contact layers
        if (i < num_source_inj && j == 0)
        {
            X[1 * N_full + (i + 2)] = -high_G;
            X[(i + 2) * N_full + 1] = -high_G;
        }

        if (i > (N - num_ground_ext) && j == 0)
        {
            X[0 * N_full + (i + 2)] = -high_G;
            X[(i + 2) * N_full + 0] = -high_G;
        }

        if (i == 0 && j == 0)
        {
            X[0 * N_full + 1] = -loop_G;
            X[1 * N_full + 0] = -loop_G;
        }
    }
}


template <int NTHREADS>
__global__ void get_imacro(const double *x, const double *m, double *imacro, int N)
{
    int num_threads = blockDim.x;
    int bid = blockIdx.x;
    int tid = threadIdx.x;
    int total_tid = bid * num_threads + tid;

    __shared__ double buf[NTHREADS];

    buf[tid] = 0.0;

    if ((total_tid >= 0 && total_tid < N) && (total_tid >= 2)) 
    {
        buf[tid] = x[(N + 2) * 0 + (total_tid + 2)] * (m[0] - m[total_tid + 2]);            // extracted (M[0] = 0)
    }

    int width = num_threads / 2;
    while (width != 0)
    {
        __syncthreads();
        if (tid < width)
        {
            buf[tid] += buf[tid + width];
        }
        width /= 2;
    }

    if (tid == 0)
    {
        atomicAdd(imacro, buf[0]);
    }
}

__global__ void set_ineg(double *ineg, const double *x, const double *m, double Vd, int N)
{
    // ineg is matrix N x N
    // x is matrix (N+2) x (N+2)
    // m is vector (N + 2)

    int tid_total = blockIdx.x * blockDim.x + threadIdx.x;
    int num_threads_total = blockDim.x * gridDim.x;

    for (auto idx = tid_total; idx < N * N; idx += num_threads_total)
    {
        int i = idx / N;
        int j = idx % N;

        ineg[i * N + j] = 0.0;
        double ical = x[(N + 2) * (i + 2) + (j + 2)] * (m[i + 2] - m[j + 2]);
        
        if (ical < 0 && Vd > 0)
        {
            ineg[i * N + j] = -ical;
        }
        else if (ical > 0 && Vd < 0)
        { 
            ineg[i * N + j] = -ical;
        }
    }
}


void update_power_gpu(hipblasHandle_t handle, hipsolverHandle_t handle_cusolver, GPUBuffers &gpubuf, 
                      const int num_source_inj, const int num_ground_ext, const int num_layers_contact,
                      const double Vd, const int pbc, const double high_G, const double low_G, const double loop_G, const double G0, const double tol,
                      const double nn_dist, const double m_e, const double V0, int num_metals, double *imacro,
                      const bool solve_heating_local, const bool solve_heating_global, const double alpha_disp)
{

    // ***************************************************************************************
    // 1. Update the atoms array from the sites array using copy_if with is_defect as a filter
    int *gpu_index;
    int *atom_gpu_index;
    gpuErrchk( hipMalloc((void **)&gpu_index, gpubuf.N_ * sizeof(int)) );                                           // indices of the site array
    gpuErrchk( hipMalloc((void **)&atom_gpu_index, gpubuf.N_ * sizeof(int)) );                                      // indices of the atom array

    thrust::device_ptr<int> gpu_index_ptr = thrust::device_pointer_cast(gpu_index);
    thrust::sequence(gpu_index_ptr, gpu_index_ptr + gpubuf.N_, 0);

    double *last_atom = thrust::copy_if(thrust::device, gpubuf.site_x, gpubuf.site_x + gpubuf.N_, gpubuf.site_element, gpubuf.atom_x, is_defect());
    int N_atom = last_atom - gpubuf.atom_x;
    thrust::copy_if(thrust::device, gpubuf.site_y, gpubuf.site_y + gpubuf.N_, gpubuf.site_element, gpubuf.atom_y, is_defect());
    thrust::copy_if(thrust::device, gpubuf.site_z, gpubuf.site_z + gpubuf.N_, gpubuf.site_element, gpubuf.atom_z, is_defect());
    thrust::copy_if(thrust::device, gpubuf.site_charge, gpubuf.site_charge + gpubuf.N_, gpubuf.site_element, gpubuf.atom_charge, is_defect());
    thrust::copy_if(thrust::device, gpubuf.site_element, gpubuf.site_element + gpubuf.N_, gpubuf.site_element, gpubuf.atom_element, is_defect());
    thrust::copy_if(thrust::device, gpubuf.site_CB_edge, gpubuf.site_CB_edge + gpubuf.N_, gpubuf.site_element, gpubuf.atom_CB_edge, is_defect());
    thrust::copy_if(thrust::device, gpu_index, gpu_index + gpubuf.N_, gpubuf.site_element, atom_gpu_index, is_defect());

    // ***************************************************************************************
    // 2. Assemble the transmission matrix (X) with both direct and tunnel connections and the
    // solution vector (M) which represents the current inflow/outflow

    // USE SIZE_T FOR ALLOCATIONS
    double *gpu_imacro, *gpu_m, *gpu_x, *gpu_ineg, *gpu_diag, *gpu_pdisp, *gpu_A;
    gpuErrchk( hipMalloc((void **)&gpu_imacro, 1 * sizeof(double)) );                                       // [A] The macroscopic device current
    gpuErrchk( hipMalloc((void **)&gpu_m, (N_atom + 2) * sizeof(double)) );                                 // [V] Virtual potential vector    
    gpuErrchk( hipMalloc((void **)&gpu_x, (N_atom + 2) * (N_atom + 2) * sizeof(double)) );                  // [1] Transmission matrix
    gpuErrchk( hipMalloc((void **)&gpu_ineg, N_atom * N_atom * sizeof(double)) );                           // [A] Current inflow matrix
    gpuErrchk( hipMalloc((void **)&gpu_diag, (N_atom + 2) * sizeof(double)) );                              // diagonal elements of the transmission matrix
    gpuErrchk( hipMalloc((void **)&gpu_pdisp, N_atom * sizeof(double)) );                                   // [W] Dissipated power vector
    gpuErrchk( hipMalloc((void **)&gpu_A, (N_atom + 1) * (N_atom + 1) * sizeof(double)) );                  // A - copy buffer for the transmission matrix
    hipDeviceSynchronize();

    gpuErrchk( hipMemset(gpu_x, 0, (N_atom + 2) * (N_atom + 2) * sizeof(double)) );                         // initialize the transmission matrix to zeros
    gpuErrchk( hipMemset(gpu_m, 0, (N_atom + 2) * sizeof(double)) );                                        // initialize the rhs for solving the system                                    
    thrust::device_ptr<double> m_ptr = thrust::device_pointer_cast(gpu_m);
    thrust::fill(m_ptr, m_ptr + 1, -loop_G * Vd);                                               // max Current extraction (ground)                          
    thrust::fill(m_ptr + 1, m_ptr + 2, loop_G * Vd);                                            // max Current injection (source)
    hipDeviceSynchronize();

    int num_threads = 128;
    int blocks_per_row = (N_atom - 1) / num_threads + 1;
    int num_blocks = blocks_per_row * gpubuf.N_;

    // fill off diagonals of X
    hipLaunchKernelGGL(create_X, num_blocks, num_threads, 0, 0, 
        gpu_x, gpubuf.atom_x, gpubuf.atom_y, gpubuf.atom_z,
        gpubuf.metal_types, gpubuf.atom_element, gpubuf.atom_charge, gpubuf.atom_CB_edge,
        gpubuf.lattice, pbc, high_G, low_G, loop_G,
        nn_dist, m_e, V0, num_source_inj, num_ground_ext, num_layers_contact,
        N_atom, num_metals, Vd, tol);
    gpuErrchk( hipPeekAtLastError() );
    hipDeviceSynchronize();

    // fill diagonal of X (all rows sum to zero)
    gpuErrchk( hipMemset(gpu_diag, 0, (N_atom + 2) * sizeof(double)) );
    num_threads = 512;
    blocks_per_row = (N_atom + 2 - 1) / num_threads + 1;
    num_blocks = blocks_per_row * (gpubuf.N_ + 2);
    row_reduce<NUM_THREADS><<<num_blocks, num_threads, NUM_THREADS * sizeof(double)>>>(gpu_x, gpu_diag, N_atom + 2);
    gpuErrchk( hipPeekAtLastError() );
    hipDeviceSynchronize();
    hipLaunchKernelGGL(write_to_diag, blocks_per_row, num_threads, 0, 0, gpu_x, gpu_diag, N_atom + 2);
    gpuErrchk( hipPeekAtLastError() );
    hipDeviceSynchronize();

    // ************************************************************
    // 2. Solve system of linear equations using LU (direct solver)

    int lwork = 0;              /* size of workspace */
    double *gpu_work = nullptr; /* device workspace for getrf */
    int *gpu_info = nullptr;    /* error info */
    int *gpu_ipiv;

    gpuErrchk( hipMalloc((void **)&gpu_ipiv, (N_atom + 1) * sizeof(int)) );
    gpuErrchk( hipMalloc((void **)(&gpu_info), sizeof(int)) );
    gpuErrchk( hipMemcpy2D(gpu_A, (N_atom + 1) * sizeof(double), gpu_x, (N_atom + 2) * sizeof(double), (N_atom + 1) * sizeof(double), (N_atom + 1), hipMemcpyDeviceToDevice) );
    hipDeviceSynchronize();

    // Solve Ax=B through LU factorization
    CheckCusolverDnError(hipsolverDnDgetrf_bufferSize(handle_cusolver, N_atom + 1, N_atom + 1, gpu_A, N_atom + 1, &lwork));
    gpuErrchk( hipMalloc((void **)(&gpu_work), sizeof(double) * lwork) );
    hipDeviceSynchronize();
    CheckCusolverDnError(hipsolverDnDgetrf(handle_cusolver, N_atom + 1, N_atom + 1, gpu_A, N_atom + 1, gpu_work, gpu_ipiv, gpu_info));
    hipDeviceSynchronize();
    CheckCusolverDnError(hipsolverDnDgetrs(handle_cusolver, HIPSOLVER_OP_T, N_atom + 1, 1, gpu_A, N_atom + 1, gpu_ipiv, gpu_m, N_atom + 1, gpu_info));
    hipDeviceSynchronize();

    int host_info;
    gpuErrchk( hipMemcpy(&host_info, gpu_info, sizeof(int), hipMemcpyDeviceToHost) );
    if (host_info)
    {
        std::cout << "WARNING: Info for gesv in update_power is " << host_info << "\n";
    }

    double check_element;
    gpuErrchk( hipMemcpy(&check_element, gpu_m + num_source_inj, sizeof(double), hipMemcpyDeviceToHost) );
    if (std::abs(check_element - Vd) > 0.1)
    {
        std::cout << "WARNING: non-negligible potential drop of " << std::abs(check_element - Vd) <<
                    " across the contact at VD = " << Vd << "\n";
    }

    // scale the virtual potentials by G0 (conductance quantum) instead of multiplying inside the X matrix
    thrust::device_ptr<double> gpu_m_ptr = thrust::device_pointer_cast(gpu_m);
    thrust::transform(gpu_m_ptr, gpu_m_ptr + N_atom + 1, gpu_m_ptr, thrust::placeholders::_1 * G0);

    // ****************************************************
    // 3. Calculate the net current flowing into the device

    num_threads = 512;
    num_blocks = (N_atom - 1) / num_threads + 1;
    gpuErrchk( hipMemset(gpu_imacro, 0, sizeof(double)) ); 
    get_imacro<NUM_THREADS><<<num_blocks, num_threads, NUM_THREADS * sizeof(double)>>>(gpu_x, gpu_m, gpu_imacro, N_atom);
    gpuErrchk( hipPeekAtLastError() );
    hipDeviceSynchronize();
    gpuErrchk( hipMemcpy(imacro, gpu_imacro, sizeof(double), hipMemcpyDeviceToHost) );
    std::cout << "I_macro: " << *imacro * (1e6) << "\n";

    // **********************************************
    // 4. Calculate the dissipated power at each atom

if (solve_heating_local || solve_heating_global)
{   
        // Shift the virtual potential so that it is all positive, as we will take differences
        double min_index = thrust::min_element(thrust::device, gpu_m + 2, gpu_m + N_atom + 2) - gpu_m;
        num_threads = 512;
        blocks_per_row = (N_atom + 2 - 1) / num_threads + 1;
        num_blocks = blocks_per_row;
        hipLaunchKernelGGL(update_m, num_blocks, num_threads, 0, 0, gpu_m, min_index, N_atom + 2);
        gpuErrchk( hipPeekAtLastError() );

        // Collect the forward currents into I_neg, the diagonals are once again the sum of each row
        num_threads = 512;
        blocks_per_row = (N_atom - 1) / num_threads + 1;
        num_blocks = blocks_per_row * gpubuf.N_;
        hipLaunchKernelGGL(set_ineg, num_blocks, num_threads, 0, 0, gpu_ineg, gpu_x, gpu_m, Vd, N_atom);
        gpuErrchk( hipPeekAtLastError() );
        hipDeviceSynchronize();
        gpuErrchk( hipMemset(gpu_diag, 0, (N_atom + 2) * sizeof(double)) );
        hipDeviceSynchronize();
        row_reduce<NUM_THREADS><<<num_blocks, num_threads, NUM_THREADS * sizeof(double)>>>(gpu_ineg, gpu_diag, N_atom);
        gpuErrchk( hipPeekAtLastError() );
        hipDeviceSynchronize();
        hipLaunchKernelGGL(write_to_diag, blocks_per_row, num_threads, 0, 0, gpu_ineg, gpu_diag, N_atom);
        gpuErrchk( hipPeekAtLastError() );
        hipDeviceSynchronize();

        // Compute the dissipated power at each atom with [P]_Nx1 = [I]_NxN * [V]_Nx1 (gemv)
        double alpha = 1.0, beta = 0.0;
        CheckCublasError( hipblasDgemv(handle, HIPBLAS_OP_T, N_atom, N_atom, &alpha, gpu_ineg, N_atom, gpu_m + 2, 1, &beta, gpu_pdisp, 1) );
        hipDeviceSynchronize();

        // Extract the power dissipated between the contacts
        num_threads = 512;
        num_blocks = (N_atom - 1) / num_threads + 1;
        num_blocks = min(65535, num_blocks);
        hipLaunchKernelGGL(copy_pdisp, num_blocks, num_threads, 0, 0, gpubuf.site_power, gpubuf.site_element, gpubuf.metal_types, gpu_pdisp, atom_gpu_index, N_atom, num_metals, alpha_disp);
        gpuErrchk( hipPeekAtLastError() );
        hipDeviceSynchronize();

        double *host_pdisp = new double[N_atom];
        hipMemcpy(host_pdisp, gpu_pdisp, N_atom * sizeof(double), hipMemcpyDeviceToHost);
        double sum = 0.0;
        for (int i = 0; i < N_atom; ++i) {
            sum += host_pdisp[i];
        }
        std::cout << "Sum of atom-resolved power * 1e9: " << sum*(1e9) << std::endl;
        // exit(1);
} // if (solve_heating_local || solve_heating_global)

    hipFree(gpu_ipiv);
    hipFree(gpu_work);
    hipFree(gpu_imacro);
    hipFree(gpu_m);
    hipFree(gpu_x);
    hipFree(gpu_ineg);
    hipFree(gpu_diag);
    hipFree(gpu_pdisp);
    hipFree(gpu_A);
    hipFree(gpu_info);
    hipFree(gpu_index);
    hipFree(atom_gpu_index);
}
